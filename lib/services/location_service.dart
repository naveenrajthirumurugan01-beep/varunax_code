import 'package:geolocator/geolocator.dart';

class LocationService {
  Future<Position> getCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Please enable location services');
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

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
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
