import 'package:hive_flutter/hive_flutter.dart';

/// Caches the last known satellite telemetry per site in a local Hive box.
///
/// When the device is offline (aeroplane mode / storm disruption), the
/// [SatelliteOverlayScreen] reads stale-but-useful data from this cache
/// instead of showing a blank screen.  When online, every fresh Firestore
/// snapshot is written back here to keep the cache current.
class SatelliteCacheService {
  static const _boxName = 'satellite_cache';

  Future<Box<Map>> _openBox() => Hive.openBox<Map>(_boxName);

  /// Persists a fresh satellite telemetry map for [siteId].
  Future<void> saveAnalysis(String siteId, Map<String, dynamic> data) async {
    final box = await _openBox();
    await box.put(siteId, data);
  }

  /// Returns the last cached telemetry for [siteId], or `null` if nothing
  /// has been cached yet (first run without network).
  Future<Map<String, dynamic>?> loadAnalysis(String siteId) async {
    final box = await _openBox();
    final raw = box.get(siteId);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  /// True if there is any cached entry for [siteId].
  Future<bool> hasCachedData(String siteId) async {
    final box = await _openBox();
    return box.containsKey(siteId);
  }
}
