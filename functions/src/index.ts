import {initializeApp} from "firebase-admin/app";
import {getFirestore} from "firebase-admin/firestore";
import {getMessaging} from "firebase-admin/messaging";
import {logger} from "firebase-functions";
import {
  onDocumentCreated,
  onDocumentUpdated,
} from "firebase-functions/v2/firestore";

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

// Roles that see the alert banner in the app (analyst_dashboard_screen.dart)
// and should be pushed a notification when a reading crosses into alert.
const ALERT_RECIPIENT_ROLES = ["analyst", "supervisor"];

/**
 * Looks up the FCM tokens for every user whose role is in
 * ALERT_RECIPIENT_ROLES. Users without a saved token (never logged in on a
 * supported platform, or push registration failed) are skipped.
 */
async function getAlertRecipientTokens(): Promise<string[]> {
  const usersSnapshot = await db
      .collection("users")
      .where("role", "in", ALERT_RECIPIENT_ROLES)
      .get();

  return usersSnapshot.docs
      .map((doc) => doc.data().fcmToken as string | undefined)
      .filter((token): token is string => Boolean(token));
}

/**
 * Sends the water-level alert push to every recipient token, dropping any
 * tokens FCM reports as no-longer-registered so they don't keep failing on
 * every future alert.
 */
async function sendAlertPush(siteName: string, level: number | undefined) {
  const tokens = await getAlertRecipientTokens();
  if (tokens.length === 0) {
    logger.info("No alert recipients with an FCM token; skipping push.");
    return;
  }

  const body = level === undefined ?
    `${siteName} has exceeded its danger threshold.` :
    `${siteName} has exceeded its danger threshold (level: ${level}).`;

  const response = await messaging.sendEachForMulticast({
    tokens,
    notification: {
      title: "⚠️ Water Level Alert",
      body,
    },
    android: {priority: "high"},
  });

  const staleTokens = response.responses
      .map((r, i) => (r.success ? null : tokens[i]))
      .filter((t): t is string => t !== null);

  if (staleTokens.length > 0) {
    await pruneStaleTokens(staleTokens);
  }

  logger.info(
      `Alert push sent for ${siteName}: ` +
      `${response.successCount} succeeded, ${response.failureCount} failed.`,
  );
}

/**
 * Clears fcmToken off any user doc holding a token FCM rejected, so the next
 * alert doesn't retry it. The user's own device will write a fresh token the
 * next time NotificationService.initialize() runs (e.g. next app open).
 */
async function pruneStaleTokens(staleTokens: string[]) {
  const snapshot = await db
      .collection("users")
      .where("fcmToken", "in", staleTokens)
      .get();

  const batch = db.batch();
  snapshot.docs.forEach((doc) => batch.update(doc.ref, {fcmToken: null}));
  await batch.commit();
}

export const onAlertReadingCreated = onDocumentCreated(
    "readings/{readingId}",
    async (event) => {
      const reading = event.data?.data();
      if (!reading?.isAlert) return;

      const siteName = await resolveSiteName(reading.siteId);
      await sendAlertPush(siteName, reading.level);
    },
);

// Readings are also updated in place in some flows (e.g. a follow-up sensor
// sync correcting a value); this covers a reading crossing into alert state
// on update rather than only at creation.
export const onAlertReadingUpdated = onDocumentUpdated(
    "readings/{readingId}",
    async (event) => {
      const before = event.data?.before.data();
      const after = event.data?.after.data();
      if (!after?.isAlert || before?.isAlert) return;

      const siteName = await resolveSiteName(after.siteId);
      await sendAlertPush(siteName, after.level);
    },
);

/** Falls back to the raw siteId if the site doc is missing or unnamed. */
async function resolveSiteName(siteId: string | undefined): Promise<string> {
  if (!siteId) return "A site";

  const siteDoc = await db.collection("sites").doc(siteId).get();
  return (siteDoc.data()?.name as string | undefined) ?? siteId;
}
