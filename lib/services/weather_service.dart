import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import '../models/weather_reading_model.dart';

/// A parsed snapshot of current weather conditions at a set of coordinates,
/// as returned by OpenWeatherMap's "current weather" endpoint. Distinct from
/// [WeatherReading], which additionally carries the siteId/timestamp needed
/// to persist a snapshot to Firestore.
class WeatherSnapshot {
  const WeatherSnapshot({
    required this.rainfall1h,
    required this.rainfall3h,
    required this.temperature,
    required this.humidity,
    required this.weatherDescription,
    required this.windSpeed,
  });

  final double rainfall1h;
  final double rainfall3h;
  final double temperature;
  final double humidity;
  final String weatherDescription;
  final double windSpeed;
}

/// Fetches current weather/rainfall data from OpenWeatherMap and persists it
/// to the `weather_data` Firestore collection, building up a paired
/// rainfall/water-level dataset for a future flood prediction model.
class WeatherService {
  static const String _apiKey = 'a085de1cc7335e9466516a6cab2e5ede';
  static const String _baseUrl =
      'https://api.openweathermap.org/data/2.5/weather';

  /// Fetches current weather for [latitude]/[longitude]. Returns `null` on
  /// any failure (no connectivity, bad response, unexpected shape) — this is
  /// always a best-effort data point, never something callers should block
  /// or fail a user-facing action on.
  Future<WeatherSnapshot?> fetchWeather(
    double latitude,
    double longitude,
  ) async {
    try {
      final uri = Uri.parse(_baseUrl).replace(
        queryParameters: {
          'lat': '$latitude',
          'lon': '$longitude',
          'appid': _apiKey,
          'units': 'metric',
        },
      );

      final response = await http.get(uri);
      if (response.statusCode != 200) return null;

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final main = body['main'] as Map<String, dynamic>?;
      if (main == null) return null;

      final rain = body['rain'] as Map<String, dynamic>?;
      final wind = body['wind'] as Map<String, dynamic>?;
      final weatherList = body['weather'] as List<dynamic>?;
      final weather = (weatherList != null && weatherList.isNotEmpty)
          ? weatherList.first as Map<String, dynamic>
          : null;

      return WeatherSnapshot(
        rainfall1h: (rain?['1h'] as num?)?.toDouble() ?? 0,
        rainfall3h: (rain?['3h'] as num?)?.toDouble() ?? 0,
        temperature: (main['temp'] as num).toDouble(),
        humidity: (main['humidity'] as num).toDouble(),
        weatherDescription: weather?['description'] as String? ?? 'unknown',
        windSpeed: (wind?['speed'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches current weather for [siteId]'s coordinates and saves it as a
  /// new document in the `weather_data` collection. Silently does nothing on
  /// failure, matching [fetchWeather]'s best-effort contract — callers
  /// should treat this as fire-and-forget.
  Future<void> recordWeatherForSite(
    String siteId,
    double latitude,
    double longitude,
  ) async {
    final snapshot = await fetchWeather(latitude, longitude);
    if (snapshot == null) return;

    final reading = WeatherReading(
      siteId: siteId,
      timestamp: DateTime.now(),
      rainfall1h: snapshot.rainfall1h,
      rainfall3h: snapshot.rainfall3h,
      temperature: snapshot.temperature,
      humidity: snapshot.humidity,
      weatherDescription: snapshot.weatherDescription,
      windSpeed: snapshot.windSpeed,
    );

    try {
      await FirebaseFirestore.instance
          .collection('weather_data')
          .add(reading.toMap());
    } catch (_) {
      // Best-effort — a failed write here should never surface to the user
      // or interrupt whatever flow triggered it.
    }
  }
}
