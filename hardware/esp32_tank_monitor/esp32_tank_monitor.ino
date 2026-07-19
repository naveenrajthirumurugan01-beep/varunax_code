/*
 * VARUNA X — ESP32 Tank Water Level Monitor
 * ------------------------------------------
 * HC-SR04 ultrasonic sensor measures distance from the top of the tank down
 * to the water surface. Existing functionality (LCD readout, buzzer alarm,
 * Blynk V0/V1 + flood_alert event) is unchanged; this sketch additionally
 * POSTs a reading to the VARUNA X Firestore database every 60 seconds so it
 * shows up in the app's analyst dashboard / supervisor review screens
 * (submittedBy: "esp32-device").
 *
 * Required libraries (Arduino Library Manager):
 *   - Blynk (Blynk IoT / Legacy Blynk library for ESP32)
 *   - LiquidCrystal (built into the Arduino IDE core — no install needed;
 *     this is the parallel-interface 16x2 LCD driver, not I2C)
 *   - ArduinoJson (v6+) — used to build the Firestore REST payload safely
 *
 * Wiring (adjust the #define pins below to match your actual wiring):
 *   - HC-SR04:  TRIG -> GPIO5, ECHO -> GPIO18 (use a voltage divider on
 *               ECHO — it's 5V logic, ESP32 GPIOs are 3.3V only)
 *   - Buzzer:   GPIO19
 *   - LCD:      Parallel (4-bit mode) — RS -> GPIO13, E -> GPIO12,
 *               D4 -> GPIO14, D5 -> GPIO27, D6 -> GPIO26, D7 -> GPIO25
 *
 * IMPORTANT — Firestore security rules:
 *   This sketch posts with no Authorization header at all, matching "test
 *   mode" (open read/write) rules. The firestore.rules file actually
 *   checked into the VARUNA X repo requires request.auth != null on
 *   `readings` writes — if/when that ruleset is deployed to this project,
 *   these unauthenticated POSTs will start failing with 403
 *   PERMISSION_DENIED. This is a real gap between "what's deployed right
 *   now" and "what's in source control" — worth resolving deliberately
 *   (e.g. a dedicated device credential) rather than by surprise.
 *
 * IMPORTANT — timestamp field:
 *   The VARUNA X Flutter app's Reading.fromMap() calls `.toDate()` on the
 *   `timestamp` field, which only works if Firestore stored a real
 *   Timestamp. A plain epoch-millisecond integer would make every screen
 *   that lists readings (analyst dashboard, supervisor review/history)
 *   throw as soon as it reached one of these documents. So instead of an
 *   integer, this sketch NTP-syncs the clock and sends timestamp as a
 *   Firestore `timestampValue` (an RFC3339 UTC string) — Firestore stores
 *   that as a genuine Timestamp, and the existing Dart parsing code works
 *   completely unchanged.
 *
 * IMPORTANT — photoUrl / latitude / longitude:
 *   Reading.fromMap() treats photoUrl, latitude, and longitude as
 *   *required* (non-nullable) fields — a document missing any of them
 *   throws a type-cast error the instant the app tries to read it back.
 *   The spec's field list didn't include these, so this sketch sends
 *   photoUrl as "" (empty string — every screen that renders photoUrl
 *   already has an errorBuilder/placeholder for exactly this case) and
 *   latitude/longitude as the fixed LATITUDE/LONGITUDE constants below.
 *   Replace those two constants with the tank's real coordinates if
 *   known; 0,0 is used as a placeholder otherwise.
 */

// ---- Blynk credentials — MUST be defined before BlynkSimpleEsp32.h ----
#define BLYNK_TEMPLATE_NAME "river monitoring"
#define BLYNK_AUTH_TOKEN    "0yI_dUl2m05MR6F1P3zgWnjAHuomHRBk"

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <LiquidCrystal.h>
#include <ArduinoJson.h>
#include <BlynkSimpleEsp32.h>
#include <time.h>

// ---- WiFi ----
const char* WIFI_SSID     = "Hackathon";
const char* WIFI_PASSWORD = "Hack@2025";

// ---- Firestore ----
const char* FIRESTORE_PROJECT_ID = "varuna-x-28174";
const char* FIRESTORE_URL =
    "https://firestore.googleapis.com/v1/projects/varuna-x-28174/databases/(default)/documents/readings";
const char* SITE_ID      = "test-site-esp32";
const char* SUBMITTED_BY = "esp32-device";
// Placeholder location — see the photoUrl/latitude/longitude note above.
const double LATITUDE  = 0.0;
const double LONGITUDE = 0.0;
const unsigned long FIRESTORE_POST_INTERVAL_MS = 60000; // 60 seconds

// ---- Tank geometry ----
const float TANK_DEPTH_CM      = 34.7;
const float ALERT_THRESHOLD_CM = 18.7;

// ---- HC-SR04 pins ----
const int TRIG_PIN = 5;
const int ECHO_PIN = 18;

// ---- Buzzer ----
const int BUZZER_PIN = 19;

// ---- LCD (16x2, parallel 4-bit interface) ----
LiquidCrystal lcd(13, 12, 14, 27, 26, 25);

unsigned long lastFirestorePost = 0;
bool wasAlerting = false;

// ---- HC-SR04 distance measurement ----
// Returns distance in cm from the sensor down to the water surface, or
// NAN if the sensor timed out (no echo — out of range/disconnected).
float readDistanceCm() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  // 30ms timeout ≈ ~5m round trip, comfortably more than this tank needs.
  unsigned long durationUs = pulseIn(ECHO_PIN, HIGH, 30000UL);
  if (durationUs == 0) {
    return NAN;
  }

  // Speed of sound ≈ 0.0343 cm/us; divide by 2 for the round trip.
  return (durationUs * 0.0343f) / 2.0f;
}

void connectWiFi() {
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    Serial.print(".");
  }
  Serial.println();
  Serial.print("WiFi connected, IP: ");
  Serial.println(WiFi.localIP());
}

// NTP sync so we can send a real UTC timestamp to Firestore (see the
// timestamp note in the file header for why this matters).
void syncTime() {
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  Serial.print("Waiting for NTP time sync");
  time_t now = time(nullptr);
  // 8 * 3600 is an arbitrary "clearly not synced yet" sentinel — any real
  // NTP-synced time.now() will be far larger than this.
  while (now < 8 * 3600) {
    delay(300);
    Serial.print(".");
    now = time(nullptr);
  }
  Serial.println();
  Serial.println("Time synced.");
}

// Formats the current UTC time as an RFC3339 string, e.g.
// "2026-07-19T12:34:56Z" — the format Firestore's REST API expects for a
// timestampValue field.
String currentTimestampRfc3339() {
  time_t now = time(nullptr);
  struct tm timeinfo;
  gmtime_r(&now, &timeinfo);
  char buffer[25];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
  return String(buffer);
}

// Builds the Firestore REST "create document" JSON body and POSTs it.
// Fire-and-forget from the caller's perspective: logs failures to Serial
// but never blocks the LCD/buzzer/Blynk loop below.
void postReadingToFirestore(float waterDepthCm, bool isAlert) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("Firestore POST skipped: WiFi not connected.");
    return;
  }

  WiFiClientSecure client;
  // Hackathon-scope shortcut: skips certificate validation rather than
  // embedding Google's root CA. Matches the "no auth needed, test mode"
  // security posture already accepted for this project — do not carry
  // into a production deployment.
  client.setInsecure();

  HTTPClient http;
  if (!http.begin(client, FIRESTORE_URL)) {
    Serial.println("Firestore POST failed: could not begin HTTP request.");
    return;
  }
  http.addHeader("Content-Type", "application/json");

  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["siteId"]["stringValue"]         = SITE_ID;
  fields["manualLevel"]["doubleValue"]    = waterDepthCm;
  fields["aiDetectedLevel"]["doubleValue"]= waterDepthCm;
  fields["status"]["stringValue"]         = "pending";
  fields["timestamp"]["timestampValue"]   = currentTimestampRfc3339();
  fields["submittedBy"]["stringValue"]    = SUBMITTED_BY;
  fields["isAlert"]["booleanValue"]       = isAlert;
  // Required by the app's Reading model even though not in the original
  // field list — see the photoUrl/latitude/longitude note above.
  fields["photoUrl"]["stringValue"]       = "";
  fields["latitude"]["doubleValue"]       = LATITUDE;
  fields["longitude"]["doubleValue"]      = LONGITUDE;

  String payload;
  serializeJson(doc, payload);

  int statusCode = http.POST(payload);
  if (statusCode > 0) {
    Serial.print("Firestore POST status: ");
    Serial.println(statusCode);
    if (statusCode >= 300) {
      Serial.println("Firestore response body:");
      Serial.println(http.getString());
    }
  } else {
    Serial.print("Firestore POST failed, error: ");
    Serial.println(http.errorToString(statusCode));
  }

  http.end();
}

void setup() {
  Serial.begin(115200);

  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  lcd.begin(16, 2);
  lcd.setCursor(0, 0);
  lcd.print("VARUNA X Monitor");

  connectWiFi();
  syncTime();

  Blynk.config(BLYNK_AUTH_TOKEN);
  Blynk.connect();

  lastFirestorePost = millis();
}

void loop() {
  Blynk.run();

  float distanceCm = readDistanceCm();
  if (isnan(distanceCm)) {
    Serial.println("HC-SR04: no echo received, skipping this cycle.");
    delay(1000);
    return;
  }

  float waterDepthCm = TANK_DEPTH_CM - distanceCm;
  // Clamp to a sane range — an out-of-range echo can otherwise produce a
  // wildly negative or oversized depth.
  if (waterDepthCm < 0)              waterDepthCm = 0;
  if (waterDepthCm > TANK_DEPTH_CM)  waterDepthCm = TANK_DEPTH_CM;

  bool isAlert = waterDepthCm >= ALERT_THRESHOLD_CM;

  // ---- LCD ----
  lcd.setCursor(0, 0);
  lcd.print("Depth: ");
  lcd.print(waterDepthCm, 1);
  lcd.print(" cm   ");
  lcd.setCursor(0, 1);
  lcd.print(isAlert ? "ALERT: FLOODING!" : "Status: Normal  ");

  // ---- Buzzer ----
  digitalWrite(BUZZER_PIN, isAlert ? HIGH : LOW);

  // ---- Blynk V0/V1 ----
  Blynk.virtualWrite(V0, waterDepthCm);
  Blynk.virtualWrite(V1, isAlert ? 1 : 0);

  // Fire flood_alert once per crossing into alert state, not every loop,
  // so a sustained flood doesn't spam the Blynk event log.
  if (isAlert && !wasAlerting) {
    Blynk.logEvent("flood_alert", "Tank water depth reached " +
                                       String(waterDepthCm, 1) + " cm");
  }
  wasAlerting = isAlert;

  // ---- Firestore POST every 60 seconds (non-blocking) ----
  unsigned long nowMs = millis();
  if (nowMs - lastFirestorePost >= FIRESTORE_POST_INTERVAL_MS) {
    lastFirestorePost = nowMs;
    postReadingToFirestore(waterDepthCm, isAlert);
  }

  delay(1000);
}
