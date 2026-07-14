import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../services/ai_detection_service.dart';
import '../../services/auth_service.dart';
import '../../services/cloudinary_service.dart';
import '../../services/location_service.dart';
import '../../services/sync_service.dart';

enum _CaptureStage {
  checkingLocation,
  outsideGeofence,
  insideGeofence,
  camera,
  preview,
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.site});

  final Site site;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _locationService = LocationService();
  final _aiDetectionService = AiDetectionService();
  final _levelController = TextEditingController();

  _CaptureStage _stage = _CaptureStage.checkingLocation;
  String? _errorMessage;
  double? _userLatitude;
  double? _userLongitude;
  double? _distanceMeters;

  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;
  XFile? _capturedPhoto;
  Uint8List? _capturedPhotoBytes;
  bool _isSaving = false;

  bool _isDetectingLevel = false;
  double? _aiDetectedLevel;

  double? get _parsedLevel => double.tryParse(_levelController.text.trim());

  bool get _canSubmit =>
      _parsedLevel != null &&
      _capturedPhoto != null &&
      _userLatitude != null &&
      _userLongitude != null;

  @override
  void initState() {
    super.initState();
    _checkLocation();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _levelController.dispose();
    _aiDetectionService.dispose();
    super.dispose();
  }

  // ---- Geofence check logic (unchanged) ----

  Future<void> _checkLocation() async {
    setState(() {
      _stage = _CaptureStage.checkingLocation;
      _errorMessage = null;
    });

    try {
      final position = await _locationService.getCurrentLocation();
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        widget.site.latitude,
        widget.site.longitude,
      );
      final withinGeofence = _locationService.isWithinGeofence(
        position.latitude,
        position.longitude,
        widget.site.latitude,
        widget.site.longitude,
        widget.site.allowedRadius,
      );

      if (!mounted) return;
      setState(() {
        _userLatitude = position.latitude;
        _userLongitude = position.longitude;
        _distanceMeters = distance;
        _stage = withinGeofence
            ? _CaptureStage.insideGeofence
            : _CaptureStage.outsideGeofence;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _stage = _CaptureStage.outsideGeofence;
      });
    }
  }

  // ---- Live camera capture logic (unchanged) ----

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _errorMessage = 'No camera available on this device.';
        });
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      setState(() {
        _cameraController = controller;
        _cameraInitFuture = controller.initialize();
        _stage = _CaptureStage.camera;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Could not open camera: $e';
      });
    }
  }

  Future<void> _takePicture() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      final photo = await controller.takePicture();
      // Image.file (used to preview the photo below) isn't supported on
      // Flutter Web, so read the bytes up front and use Image.memory there.
      final bytes = kIsWeb ? await photo.readAsBytes() : null;
      if (!mounted) return;
      setState(() {
        _capturedPhoto = photo;
        _capturedPhotoBytes = bytes;
        _stage = _CaptureStage.preview;
      });
      unawaited(_runAiDetection(photo.path));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to capture photo: $e';
      });
    }
  }

  // ---- AI-assisted gauge reading detection ----
  //
  // Runs on-device OCR in the background right after a photo is taken. This
  // is only ever a suggestion for the officer to verify — never trusted or
  // submitted on its own.

  Future<void> _runAiDetection(String imagePath) async {
    // google_mlkit_text_recognition has no web implementation, so skip
    // detection entirely on web rather than let it fail — the water level
    // card shows a message and the officer just enters the level manually.
    if (kIsWeb) return;

    setState(() {
      _isDetectingLevel = true;
    });

    final detected = await _aiDetectionService.detectWaterLevel(imagePath);

    if (!mounted) return;
    setState(() {
      _isDetectingLevel = false;
      _aiDetectedLevel = detected;
      if (detected != null) {
        _levelController.text = _formatLevel(detected);
      }
    });
  }

  String _formatLevel(double value) {
    return value == value.truncateToDouble()
        ? value.toStringAsFixed(1)
        : value.toString();
  }

  void _retake() {
    setState(() {
      _capturedPhoto = null;
      _capturedPhotoBytes = null;
      _stage = _CaptureStage.camera;
      _isDetectingLevel = false;
      _aiDetectedLevel = null;
    });
  }

  // ---- Save / offline sync logic (unchanged, now also carries manualLevel) ----

  Future<void> _confirmPhoto() async {
    final photo = _capturedPhoto;
    final level = _parsedLevel;
    if (photo == null ||
        level == null ||
        _userLatitude == null ||
        _userLongitude == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    // Everything from the connectivity check onward is now inside one
    // try/catch — previously the connectivity check and the offline-save
    // branch sat outside it, so an error there (e.g. a web-incompatible
    // file-path read) went uncaught: _isSaving stayed true forever with no
    // SnackBar and no navigation, making the button look like it did nothing.
    try {
      final connectivityResults = await Connectivity().checkConnectivity();
      final isOnline = !connectivityResults.contains(ConnectivityResult.none);

      if (!isOnline) {
        final readingId = FirebaseFirestore.instance
            .collection('readings')
            .doc()
            .id;
        final offlineReading = Reading(
          readingId: readingId,
          siteId: widget.site.siteId,
          submittedBy: AuthService().currentUser?.uid ?? 'unknown',
          timestamp: DateTime.now(),
          latitude: _userLatitude!,
          longitude: _userLongitude!,
          photoUrl: '',
          manualLevel: level,
          aiDetectedLevel: _aiDetectedLevel,
          status: 'pending',
          supervisorNote: null,
        );

        await SyncService().saveReadingOffline(offlineReading, photo.path);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No internet — reading saved locally, will sync automatically',
            ),
          ),
        );
        Navigator.of(context).pop();
        return;
      }

      final readingRef = FirebaseFirestore.instance
          .collection('readings')
          .doc();
      final timestamp = DateTime.now();

      // Photos are uploaded to Cloudinary rather than Firebase Storage.
      // photo.path is a blob: URL on web, which File() can't read, so pass
      // the in-memory bytes already captured for the preview instead.
      final String photoUrl;
      if (kIsWeb) {
        final bytes = _capturedPhotoBytes;
        if (bytes == null) {
          throw StateError('Captured photo bytes are not available.');
        }
        photoUrl = await CloudinaryService().uploadImage(bytes);
      } else {
        photoUrl = await CloudinaryService().uploadImage(photo.path);
      }

      final reading = Reading(
        readingId: readingRef.id,
        siteId: widget.site.siteId,
        submittedBy: AuthService().currentUser?.uid ?? 'unknown',
        timestamp: timestamp,
        latitude: _userLatitude!,
        longitude: _userLongitude!,
        photoUrl: photoUrl,
        manualLevel: level,
        aiDetectedLevel: _aiDetectedLevel,
        status: 'pending',
        supervisorNote: null,
      );

      await readingRef.set(reading.toMap());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reading saved successfully')),
      );
      Navigator.of(context).pop();
    } catch (e, stackTrace) {
      debugPrint('Failed to save reading: $e\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save reading: $e')));
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.site.name)),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    // The live camera view and photo preview take over the full screen,
    // exactly as before.
    switch (_stage) {
      case _CaptureStage.camera:
        return _buildCameraPreview();
      case _CaptureStage.preview:
        return _buildPhotoPreview();
      case _CaptureStage.checkingLocation:
      case _CaptureStage.outsideGeofence:
      case _CaptureStage.insideGeofence:
        return _buildForm();
    }
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSiteInfoCard(),
          const SizedBox(height: 12),
          _buildWaterLevelCard(),
          const SizedBox(height: 12),
          _buildGeofenceSection(),
        ],
      ),
    );
  }

  Widget _buildSiteInfoCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Site Information',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.site.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.site.siteCode} • ${widget.site.riverName}',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWaterLevelCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Water Level Reading',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _levelController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Enter level in meters',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'AI-assisted reading detection isn\'t available on web — '
                      'please enter the level manually.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ] else if (_isDetectingLevel) ...[
              const SizedBox(height: 8),
              const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Analyzing gauge reading...',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ] else if (_aiDetectedLevel != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 14,
                    color: Colors.blue.shade600,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'AI suggested — please verify',
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: Colors.blue.shade600,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Danger Level: ${widget.site.dangerLevel} m',
              style: const TextStyle(
                color: Colors.orange,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeofenceSection() {
    switch (_stage) {
      case _CaptureStage.checkingLocation:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Checking your location...'),
            ],
          ),
        );
      case _CaptureStage.outsideGeofence:
        // Geofence check failed — block everything below this point.
        return _buildOutsideGeofence();
      case _CaptureStage.insideGeofence:
        return _buildInsideGeofence();
      case _CaptureStage.camera:
      case _CaptureStage.preview:
        return const SizedBox.shrink();
    }
  }

  Widget _buildOutsideGeofence() {
    final message =
        _errorMessage ??
        'You are ${_distanceMeters!.toStringAsFixed(0)} meters away from '
            '${widget.site.name}. You must be within '
            '${widget.site.allowedRadius.toStringAsFixed(0)}m to capture a reading.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.location_off, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _checkLocation,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry / Refresh Location'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInsideGeofence() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: const [
                Icon(Icons.location_on, color: Colors.blue),
                SizedBox(width: 12),
                Text('Using device location'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_errorMessage != null) ...[
          Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
        ],
        ElevatedButton.icon(
          onPressed: _openCamera,
          icon: const Icon(Icons.camera_alt),
          label: const Text('Open Camera'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraController;
    final initFuture = _cameraInitFuture;
    if (controller == null || initFuture == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return FutureBuilder<void>(
      future: initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Camera error: ${snapshot.error}'));
        }
        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Positioned.fill(child: CameraPreview(controller)),
            Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: FloatingActionButton(
                onPressed: _takePicture,
                child: const Icon(Icons.camera),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPhotoPreview() {
    final photo = _capturedPhoto;
    if (photo == null) {
      return const Center(child: Text('No photo captured.'));
    }

    final Widget photoPreview;
    if (kIsWeb) {
      final bytes = _capturedPhotoBytes;
      photoPreview = bytes == null
          ? const Center(child: CircularProgressIndicator())
          : Image.memory(bytes, fit: BoxFit.cover, width: double.infinity);
    } else {
      photoPreview = Image.file(
        File(photo.path),
        fit: BoxFit.cover,
        width: double.infinity,
      );
    }

    // Everything below scrolls as one column so the preview's fixed height
    // never pushes the Retake/Submit buttons off-screen and out of reach.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 350, child: photoPreview),
          const SizedBox(height: 12),
          _buildWaterLevelCard(),
          const SizedBox(height: 16),
          _isSaving
              ? const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Saving reading...'),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _retake,
                        child: const Text('Retake'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _canSubmit ? _confirmPhoto : null,
                        child: const Text('Submit Reading'),
                      ),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}
