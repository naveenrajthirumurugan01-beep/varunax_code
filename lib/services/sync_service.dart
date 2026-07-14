import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/reading_model.dart';
import 'cloudinary_service.dart';

class SyncService {
  static const String pendingReadingsBoxName = 'pending_readings';

  Future<Box<Map>> _openBox() {
    return Hive.openBox<Map>(pendingReadingsBoxName);
  }

  Future<void> saveReadingOffline(
    Reading reading,
    String localPhotoPath,
  ) async {
    final box = await _openBox();
    await box.put(reading.readingId, {
      'reading': reading.toMap(),
      'localPhotoPath': localPhotoPath,
    });
  }

  Future<int> getPendingCount() async {
    final box = await _openBox();
    return box.length;
  }

  Future<bool> _hasConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    return !results.contains(ConnectivityResult.none);
  }

  Future<void> syncPendingReadings() async {
    if (!await _hasConnectivity()) return;

    final box = await _openBox();

    for (final key in box.keys.toList()) {
      final entry = box.get(key);
      if (entry == null) continue;

      try {
        final readingMap = Map<String, dynamic>.from(entry['reading'] as Map);
        final localPhotoPath = entry['localPhotoPath'] as String;
        final pendingReading = Reading.fromMap(readingMap);

        final photoFile = File(localPhotoPath);
        if (!await photoFile.exists()) {
          await box.delete(key);
          continue;
        }

        final photoUrl = await CloudinaryService().uploadImage(
          photoFile.path,
        );

        final syncedReading = Reading(
          readingId: pendingReading.readingId,
          siteId: pendingReading.siteId,
          submittedBy: pendingReading.submittedBy,
          timestamp: pendingReading.timestamp,
          latitude: pendingReading.latitude,
          longitude: pendingReading.longitude,
          photoUrl: photoUrl,
          manualLevel: pendingReading.manualLevel,
          aiDetectedLevel: pendingReading.aiDetectedLevel,
          status: pendingReading.status,
          supervisorNote: pendingReading.supervisorNote,
        );

        await FirebaseFirestore.instance
            .collection('readings')
            .doc(syncedReading.readingId)
            .set(syncedReading.toMap());

        await box.delete(key);
      } catch (_) {
        // Leave this entry in the box; it will retry on the next sync pass.
      }
    }
  }
}
