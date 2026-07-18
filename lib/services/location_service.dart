import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocationService {
  Future<Position> getCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Please enable GPS/Location Services on your device');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission denied');
    }

    Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 30),
        ),
      );
    } on TimeoutException {
      // A GPS cold start under LocationAccuracy.high (no network-based
      // assistance) can take longer than 30s to get a satellite fix —
      // retry once with the more tolerant LocationAccuracy.medium before
      // giving up entirely.
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 30),
        ),
      );
    }

    await _cacheLocation(position);
    return position;
  }

  // Cached so the last known fix survives app restarts — useful as a
  // reference point in the Airplane Mode / no-network scenario, where the
  // officer may still want to see where they last successfully checked in.
  Future<void> _cacheLocation(Position position) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_known_latitude', position.latitude);
    await prefs.setDouble('last_known_longitude', position.longitude);
    await prefs.setInt(
      'last_known_location_timestamp',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  bool isWithinGeofence(
    double userLat,
    double userLng,
    double siteLat,
    double siteLng,
    double allowedRadiusMeters,
  ) {
    final distance = Geolocator.distanceBetween(
      userLat,
      userLng,
      siteLat,
      siteLng,
    );
    return distance <= allowedRadiusMeters;
  }
}
