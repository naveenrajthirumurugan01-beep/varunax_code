import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/theme.dart';
import '../../l10n/app_localizations.dart';
import '../../models/reading_model.dart';
import '../../models/site_model.dart';
import '../../models/weather_reading_model.dart';
import '../../services/ai_detection_service.dart';
import '../../services/auth_service.dart';
import '../../services/cascade_alert_service.dart';
import '../../services/cloudinary_service.dart';
import '../../services/image_quality_service.dart';
import '../../services/location_service.dart';
import '../../services/ph_detection_service.dart';
import '../../services/push_sender_service.dart';
import '../../services/segmentation_service.dart';
import '../../services/sync_service.dart';
import '../../services/weather_service.dart';
import 'submission_result_screen.dart';

enum _CaptureStage {
  checkingLocation,
  outsideGeofence,
  insideGeofence,
  camera,
  preview,
  scanningPhStrip,
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
  final _segmentationService = SegmentationService();
  final _levelController = TextEditingController();
  final _phLevelController = TextEditingController();

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

  bool _isDetectingWaterLine = false;
  double? _aiDetectedWaterLinePercent;

  // Tracks whether the level field currently holds a value we filled in from
  // AI detection (vs one the officer typed) so the UI knows whether to show
  // the "please verify" label and whether a later detection is still allowed
  // to overwrite the field.
  bool _isLevelAutoFilled = false;
  bool _userEditedLevel = false;
  double? _aiCalibratedSegmentationLevel;
  bool _isSubmerged = false;
  bool _isBlurryOrDark = false;

  double? get _parsedLevel => double.tryParse(_levelController.text.trim());

  // Optional â€” a missing or unparsable pH reading never blocks submission,
  // unlike the water level field above.
  double? get _parsedPhLevel {
    final text = _phLevelController.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  bool get _canSubmit =>
      _parsedLevel != null &&
      _capturedPhoto != null &&
      _userLatitude != null &&
      _userLongitude != null;

  // ---- pH strip scanning state ----
  //
  // A separate, self-contained camera session from the main gauge-photo
  // flow above â€” entered/exited via its own methods, never touching
  // _cameraController/_cameraInitFuture or the .camera/.preview stages.

  // Centered 50% square of the full captured image, as fractions of its
  // width/height â€” a deliberately generous approximation of whatever's
  // under the on-screen guide box (see _buildPhStripCamera's comment on why
  // that preview isn't cropped/scaled, which keeps this mapping honest).
  static const _phSampleRegion = Rect.fromLTRB(0.25, 0.25, 0.75, 0.75);

  CameraController? _phCameraController;
  Future<void>? _phCameraInitFuture;
  _CaptureStage? _stageBeforePhScan;
  bool _isDetectingPh = false;
  bool _hasAttemptedPhScan = false;
  PhDetectionResult? _phDetectionResult;
  WaterQualityAssessment? _waterQualityAssessment;

  @override
  void initState() {
    super.initState();
    _checkLocation();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _phCameraController?.dispose();
    _levelController.dispose();
    _phLevelController.dispose();
    _aiDetectionService.dispose();
    _segmentationService.dispose();
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
      unawaited(_checkImageQuality(photo.path));
      unawaited(_runAiDetection(photo.path));
      unawaited(_runSegmentation(photo.path));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to capture photo: $e';
      });
    }
  }

  Future<void> _checkImageQuality(String imagePath) async {
    final result = await ImageQualityService().analyzeImage(imagePath);
    if (!mounted) return;
    setState(() {
      _isBlurryOrDark = result.isBlurry || result.isDark;
    });
    if (_isBlurryOrDark) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '⚠️ Warning: Image appears blurry or too dark. Please consider retaking for an accurate reading.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  // ---- AI-assisted gauge reading detection ----
  //
  // Runs on-device OCR in the background right after a photo is taken. This
  // is only ever a suggestion for the officer to verify â€” never trusted or
  // submitted on its own.

  Future<void> _runAiDetection(String imagePath) async {
    // google_mlkit_text_recognition has no web implementation, so skip
    // detection entirely on web rather than let it fail â€” the water level
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
    });
  }

  String _formatLevel(double value) {
    return value == value.truncateToDouble()
        ? value.toStringAsFixed(1)
        : value.toString();
  }

  // ---- AI-assisted water-line segmentation ----
  //
  // Runs the bundled ONNX segmentation model in the background right after a
  // photo is taken, alongside the OCR detection above. Also only ever a
  // suggestion for the officer to verify.

  Future<void> _runSegmentation(String imagePath) async {
    // onnxruntime has no web implementation, so skip detection entirely on
    // web rather than let it fail.
    if (kIsWeb) return;

    setState(() {
      _isDetectingWaterLine = true;
    });

    final result = await _segmentationService.detectWaterLevel(imagePath);

    if (!mounted) return;
    setState(() {
      _isDetectingWaterLine = false;
      _aiDetectedWaterLinePercent = result?.waterLinePercent;
      if (result != null) {
        final calibrated = widget.site.getCalibratedLevel(result.waterLinePercent);
        _aiCalibratedSegmentationLevel = calibrated;

        // If water reaches the top of the frame (waterLinePercent <= 5%) and OCR fails,
        // flag the gauge post as submerged and default level to max calibrated point.
        if (result.waterLinePercent <= 5.0 && _aiDetectedLevel == null) {
          _isSubmerged = true;
        }

        if (_aiDetectedLevel == null && !_userEditedLevel) {
          _levelController.text = _formatLevel(_isSubmerged ? (widget.site.maxGaugeHeight ?? widget.site.dangerLevel * 1.15) : calibrated);
          _isLevelAutoFilled = true;
        }
      }
    });
  }

  void _retake() {
    setState(() {
      _capturedPhoto = null;
      _capturedPhotoBytes = null;
      _stage = _CaptureStage.camera;
      _isDetectingLevel = false;
      _aiDetectedLevel = null;
      _isDetectingWaterLine = false;
      _aiDetectedWaterLinePercent = null;
      _isLevelAutoFilled = false;
      _userEditedLevel = false;
      _aiCalibratedSegmentationLevel = null;
      _isSubmerged = false;
      _isBlurryOrDark = false;
    });
  }

  // ---- pH strip scanning ----
  //
  // Mirrors _openCamera/_takePicture's structure, but is entirely
  // self-contained: its own controller, its own stage, and it always
  // returns to whichever stage the officer was on before opening it.

  Future<void> _openPhStripCamera() async {
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
        _stageBeforePhScan = _stage;
        _phCameraController = controller;
        _phCameraInitFuture = controller.initialize();
        _stage = _CaptureStage.scanningPhStrip;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Could not open camera: $e';
      });
    }
  }

  Future<void> _capturePhStripPhoto() async {
    final controller = _phCameraController;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() {
      _isDetectingPh = true;
    });

    PhDetectionResult? result;
    try {
      final photo = await controller.takePicture();
      result = await PhDetectionService().detectPh(
        photo.path,
        _phSampleRegion,
      );
    } catch (_) {
      // Detection failures are already handled inside PhDetectionService
      // (it returns null) â€” this only guards the capture step itself
      // (e.g. the camera erroring mid-shot).
      result = null;
    }

    if (!mounted) return;

    final assessment = result != null
        ? PhDetectionService().classifyWaterQuality(result.ph)
        : null;
    final previousStage = _stageBeforePhScan ?? _CaptureStage.insideGeofence;

    setState(() {
      _isDetectingPh = false;
      _hasAttemptedPhScan = true;
      _phDetectionResult = result;
      _waterQualityAssessment = assessment;
      _stage = previousStage;
      _phCameraController = null;
      _phCameraInitFuture = null;
    });

    await controller.dispose();
  }

  void _cancelPhStripScan() {
    final controller = _phCameraController;
    final previousStage = _stageBeforePhScan ?? _CaptureStage.insideGeofence;
    setState(() {
      _stage = previousStage;
      _phCameraController = null;
      _phCameraInitFuture = null;
    });
    controller?.dispose();
  }

  // ---- Save / offline sync logic (unchanged, now also carries manualLevel) ----

  Future<void> _confirmPhoto() async {
    final photo = _capturedPhoto;
    final level = _parsedLevel;
    final phLevel = _parsedPhLevel;
    if (photo == null ||
        level == null ||
        _userLatitude == null ||
        _userLongitude == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    // level (manualLevel) is guaranteed non-null by the early return above,
    // so there's no case here where falling back to the AI-detected value is
    // reachable â€” dart's null-safety already proves that invariant.
    final isAlert = level >= widget.site.dangerLevel;
    final warningLevel = Reading.calculateWarningLevel(
      level,
      widget.site.dangerLevel,
    );

    // Fire-and-forget: accumulates a paired rainfall/water-level dataset for
    // a future flood prediction model, but must never block or fail the
    // reading submission itself â€” recordWeatherForSite already swallows its
    // own errors (no connectivity, API failure, etc).
    unawaited(
      WeatherService().recordWeatherForSite(
        widget.site.siteId,
        widget.site.latitude,
        widget.site.longitude,
      ),
    );

    // Everything from the connectivity check onward is now inside one
    // try/catch â€” previously the connectivity check and the offline-save
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
          aiDetectedLevel: _aiDetectedLevel ?? _aiCalibratedSegmentationLevel,
          status: 'pending',
          supervisorNote: null,
          isAlert: isAlert,
          phLevel: phLevel,
          waterQualityStatus: _waterQualityAssessment?.status,
          isSubmerged: _isSubmerged,
          isBlurryOrDark: _isBlurryOrDark,
          warningLevel: warningLevel,
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
        // No already-fetched WeatherReading exists in this scope â€” weather
        // here is only ever fire-and-forget written to Firestore, never
        // read back â€” so weather is omitted rather than triggering a new
        // fetch, same as generateReadingSummary's other call sites.
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => SubmissionResultScreen(
              reading: offlineReading,
              site: widget.site,
            ),
          ),
        );
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
        aiDetectedLevel: _aiDetectedLevel ?? _aiCalibratedSegmentationLevel,
        status: 'pending',
        supervisorNote: null,
        isAlert: isAlert,
        phLevel: phLevel,
        waterQualityStatus: _waterQualityAssessment?.status,
        isSubmerged: _isSubmerged,
        isBlurryOrDark: _isBlurryOrDark,
        warningLevel: warningLevel,
      );

      await readingRef.set(reading.toMap());

      if (isAlert) {
        // Fire-and-forget: must never block or fail the reading submission
        // that triggered it.
        unawaited(
          PushSenderService().sendAlertPush(
            widget.site.name,
            level,
            widget.site.dangerLevel,
          ),
        );
        // Also fire-and-forget: flags any downstream sites as "Elevated
        // Risk" on the analyst/supervisor dashboards. Fetches all sites
        // itself, so no new data needs to be threaded through this screen.
        unawaited(
          CascadeAlertService().checkAndTriggerCascade(widget.site.siteId),
        );
      } else if (warningLevel == 'yellow' || warningLevel == 'orange') {
        // Fire-and-forget early warning — red/isAlert already covered by
        // sendAlertPush above, so this only ever fires for yellow/orange.
        unawaited(
          PushSenderService().sendWarningPush(
            widget.site.name,
            level,
            widget.site.dangerLevel,
            warningLevel!,
          ),
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reading saved successfully')),
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SubmissionResultScreen(
            reading: reading,
            site: widget.site,
          ),
        ),
      );
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
      appBar: AppBar(
        // Same pop the default back arrow already performed â€” just made
        // explicit as a close icon per the design's top bar.
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('New Reading'),
      ),
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
      case _CaptureStage.scanningPhStrip:
        return _buildPhStripCamera();
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
          _buildGaugeSection(),
          const SizedBox(height: 12),
          _buildPhSection(),
        ],
      ),
    );
  }

  Widget _buildSiteInfoCard() {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.site.name,
              style: textTheme.headlineLarge?.copyWith(
                color: const Color(0xFF000000),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.site.riverName,
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Section 1: Gauge Post Reading ----
  //
  // Camera capture (via _buildGeofenceSection, which shows the "Open Camera"
  // trigger once the officer is inside the geofence), the manual water-level
  // field, and the AI OCR/segmentation results â€” shown as a separate
  // read-only chip above the field rather than pre-filled into it, so the
  // officer always types their own reading while seeing the AI's suggestion
  // alongside it.
  Widget _buildGaugeSection() {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final currentLevel = _parsedLevel;
    final currentWarningLevel = Reading.calculateWarningLevel(
      currentLevel,
      widget.site.dangerLevel,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.gaugePostReading,
              style: textTheme.headlineMedium?.copyWith(
                color: const Color(0xFF000000),
              ),
            ),
            const SizedBox(height: 12),
            Text(l10n.waterLevelReading, style: textTheme.labelMedium),
            const SizedBox(height: 8),
            if (_aiDetectedLevel != null) ...[
              _AiPredictionChip(
                label: 'AI Predicted: ${_formatLevel(_aiDetectedLevel!)}m',
              ),
              const SizedBox(height: 8),
            ] else if (_aiDetectedWaterLinePercent != null) ...[
              // Segmentation only reports where the water line falls within
              // the frame, not a calibrated meters value, so that's spelled
              // out here rather than letting the officer think it's a real
              // gauge reading.
              _AiPredictionChip(
                label:
                    'AI Estimated: water line at '
                    '${_aiDetectedWaterLinePercent!.toStringAsFixed(0)}% of '
                    'frame height (not a calibrated reading)',
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _levelController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                hintText: l10n.enterLevelHint,
              ),
              onChanged: (_) => setState(() {
                _userEditedLevel = true;
              }),
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'AI-assisted reading detection isn\'t available on web — '
                      'please enter the level manually.',
                      style: textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              if (_isDetectingLevel) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Analyzing gauge reading...',
                      style: textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              if (_isDetectingWaterLine) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Analyzing water line...',
                      style: textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
              if (_isLevelAutoFilled && !_userEditedLevel) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 14,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Auto-filled by AI — please verify before submitting',
                        style: textTheme.labelSmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_aiDetectedLevel == null &&
                    _aiDetectedWaterLinePercent != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Calibrated from image analysis — water line detected at '
                    '${_aiDetectedWaterLinePercent!.toStringAsFixed(0)}% of '
                    'frame height.',
                    style: textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
              if (_isSubmerged) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.warning,
                      size: 16,
                      color: Colors.red,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Submerged Gauge Warning: Water level appears to be '
                        'at or above the top of the gauge post! Severe flood risk.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 12),
            _buildDangerLevelIndicator(
              l10n.dangerLevel,
              currentLevel,
              currentWarningLevel,
            ),
            const SizedBox(height: 12),
            _buildGeofenceSection(),
          ],
        ),
      ),
    );
  }

  // Below 80% of dangerLevel (warningLevel null): unchanged plain
  // "Danger Level: Xm" line. Yellow/orange/red: color-coded indicator
  // comparing the currently-typed level against the threshold.
  Widget _buildDangerLevelIndicator(
    String dangerLevelLabel,
    double? currentLevel,
    String? warningLevel,
  ) {
    if (warningLevel == null || currentLevel == null) {
      return Text(
        '$dangerLevelLabel: ${widget.site.dangerLevel} m',
        style: TextStyle(color: AppColors.error, fontWeight: FontWeight.bold),
      );
    }

    final String emoji;
    final String label;
    final Color color;
    switch (warningLevel) {
      case 'yellow':
        emoji = '🟡';
        label = 'Approaching danger';
        color = Colors.amber.shade800;
        break;
      case 'orange':
        emoji = '🟠';
        label = 'Near danger level';
        color = Colors.orange.shade800;
        break;
      default:
        emoji = '🔴';
        label = 'DANGER EXCEEDED';
        color = Colors.red.shade700;
    }

    return Text(
      '$emoji $label — ${currentLevel.toStringAsFixed(1)}m / '
      '${widget.site.dangerLevel}m',
      style: TextStyle(color: color, fontWeight: FontWeight.bold),
    );
  }

  // ---- Section 2: pH Strip Reading ----
  //
  // pH strip camera capture, the manual pH field, and the water-quality
  // classification. Same AI-vs-manual pattern as the gauge section above:
  // _PhResultCard already shows the AI-detected pH as a distinct read-only
  // card above the field, so the field itself is never pre-filled.
  Widget _buildPhSection() {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.phStripReading,
              style: textTheme.headlineMedium?.copyWith(
                color: const Color(0xFF000000),
              ),
            ),
            const SizedBox(height: 12),
            Text('pH Level (optional)', style: textTheme.labelMedium),
            const SizedBox(height: 8),
            if (_phDetectionResult != null &&
                _waterQualityAssessment != null) ...[
              _PhResultCard(
                result: _phDetectionResult!,
                assessment: _waterQualityAssessment!,
              ),
              if (_phDetectionResult!.confidence < 50) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 14, color: AppColors.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Low confidence — please verify manually',
                        style: textTheme.labelSmall?.copyWith(
                          color: AppColors.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
            ] else if (_hasAttemptedPhScan) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 14,
                    color: AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "Couldn't read a pH strip in that photo — please "
                      'enter the value manually.',
                      style: textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _phLevelController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(hintText: 'e.g. 7.2'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _isDetectingPh ? null : _openPhStripCamera,
              icon: const Icon(Icons.camera_alt_outlined),
              label: Text(
                _hasAttemptedPhScan ? 'Re-scan pH Strip' : 'Scan pH Strip',
              ),
            ),
            const SizedBox(height: 4),
            Text(
              // Honesty about the limits of this feature, right where the
              // officer is looking, not just in code comments â€” color-based
              // strip scanning from a phone photo is inherently sensitive
              // to lighting and is not a lab-grade measurement.
              'Color-based strip scanning is approximate and affected by '
              'lighting — not a lab-grade measurement. Leave blank if '
              'unavailable.',
              style: textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
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
              Text(
                'Checking your location...',
                style: TextStyle(color: Color(0xFF1A1A1A)),
              ),
            ],
          ),
        );
      case _CaptureStage.outsideGeofence:
        // Geofence check failed â€” block everything below this point.
        return _buildOutsideGeofence();
      case _CaptureStage.insideGeofence:
        return _buildInsideGeofence();
      case _CaptureStage.camera:
      case _CaptureStage.preview:
      case _CaptureStage.scanningPhStrip:
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
            const Icon(Icons.location_off, size: 64, color: AppColors.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF1A1A1A),
              ),
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
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: Colors.green.shade700, size: 18),
                const SizedBox(width: 6),
                Text(
                  l10n.withinGeofence,
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_errorMessage != null) ...[
          Text(
            _errorMessage!,
            style: TextStyle(color: AppColors.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
        ],
        ElevatedButton.icon(
          onPressed: _openCamera,
          icon: const Icon(Icons.camera_alt),
          label: const Text('Open Camera'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(AppSpacing.minTouchTarget),
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
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // CameraPreview has no built-in "cover" mode â€” it only
                  // ever letterboxes to controller.value.aspectRatio (unlike
                  // MobileScanner on the QR screen, which crops to fill on
                  // its own). Earlier attempts here tried to force a "cover"
                  // shape by handing CameraPreview a pre-computed pixel-size
                  // SizedBox, but that gives it *tight* constraints, leaving
                  // its own internal orientation-correcting AspectRatio no
                  // room to act â€” so it rendered at whatever (wrong) shape
                  // was guessed. This instead lets AspectRatio size the
                  // preview at its own correct, natural size first, then
                  // uniformly scales that correct box up with Transform.scale
                  // until it covers the screen, clipping the overscan with
                  // ClipRect â€” the same technique the camera plugin's own
                  // example app uses for a full-bleed preview.
                  final size = constraints.biggest;
                  var cameraAspectRatio = controller.value.aspectRatio;
                  if (MediaQuery.of(context).orientation == Orientation.portrait) {
                    cameraAspectRatio = 1 / cameraAspectRatio;
                  }
                  var scale = size.aspectRatio / cameraAspectRatio;
                  if (scale < 1) scale = 1 / scale;

                  return ClipRect(
                    child: Transform.scale(
                      scale: scale,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: cameraAspectRatio,
                          child: CameraPreview(controller),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Center(child: _buildShutterButton()),
            ),
          ],
        );
      },
    );
  }

  Widget _buildShutterButton() {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: _takePicture,
        customBorder: const CircleBorder(),
        child: Container(
          width: 76,
          height: 76,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: const DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildPhStripCamera() {
    final controller = _phCameraController;
    final initFuture = _phCameraInitFuture;
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

        // Deliberately not the cover-crop/Transform.scale treatment
        // _buildCameraPreview uses for the main gauge photo â€” this stays a
        // simple letterboxed AspectRatio so the visible frame maps
        // directly onto the full captured image, keeping _phSampleRegion's
        // fractional coordinates an honest match for what's on screen.
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: CameraPreview(controller),
                  ),
                ),
              ),
            ),
            const _PhGuideBox(),
            Positioned(
              top: 24,
              left: 48,
              right: 48,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(
                      AppSpacing.radiusPill,
                    ),
                  ),
                  child: const Text(
                    'Align strip within frame',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                tooltip: 'Cancel',
                onPressed: _isDetectingPh ? null : _cancelPhStripScan,
              ),
            ),
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Center(
                child: _isDetectingPh
                    ? const CircularProgressIndicator(color: Colors.white)
                    : _buildPhShutterButton(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPhShutterButton() {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: _capturePhStripPhoto,
        customBorder: const CircleBorder(),
        child: Container(
          width: 76,
          height: 76,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoPreview() {
    final l10n = AppLocalizations.of(context)!;
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
          _buildGaugeSection(),
          const SizedBox(height: 12),
          _buildPhSection(),
          const SizedBox(height: 12),
          _SiteWeatherCard(site: widget.site),
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
                    Text(
                      'Saving reading...',
                      style: TextStyle(color: Color(0xFF1A1A1A)),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton(
                      onPressed: _retake,
                      child: Text(l10n.retake),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _canSubmit ? _confirmPhoto : null,
                      icon: const Icon(Icons.upload),
                      label: Text(l10n.submitReadingButton),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}

/// Shows the site's most recent recorded weather (same `weather_data`
/// collection and shape as the analyst dashboard's weather section) on the
/// photo review screen, right next to the AI-suggested reading. If no
/// weather has ever been recorded for this site, kicks off one fresh fetch
/// via [WeatherService] as soon as the data is confirmed missing.
class _SiteWeatherCard extends StatefulWidget {
  const _SiteWeatherCard({required this.site});

  final Site site;

  @override
  State<_SiteWeatherCard> createState() => _SiteWeatherCardState();
}

class _SiteWeatherCardState extends State<_SiteWeatherCard> {
  bool _hasTriggeredFetch = false;

  void _fetchWeather() {
    _hasTriggeredFetch = true;
    unawaited(
      WeatherService().recordWeatherForSite(
        widget.site.siteId,
        widget.site.latitude,
        widget.site.longitude,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('weather_data')
              .where('siteId', isEqualTo: widget.site.siteId)
              .snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? [];
            final readings =
                docs.map((doc) => WeatherReading.fromMap(doc.data())).toList()
                  ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
            final latest = readings.isNotEmpty ? readings.first : null;

            if (latest == null &&
                !_hasTriggeredFetch &&
                snapshot.connectionState != ConnectionState.waiting) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _fetchWeather();
              });
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Current Weather at Site',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (latest == null)
                  const Text(
                    'No weather data recorded yet — fetching...',
                    style: TextStyle(color: Color(0xFF1A1A1A)),
                  )
                else ...[
                  Text(
                    'Rainfall: ${latest.rainfall1h.toStringAsFixed(1)} mm '
                    '(1h) / ${latest.rainfall3h.toStringAsFixed(1)} mm (3h)',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  Text(
                    'Temperature: ${latest.temperature.toStringAsFixed(1)}°C',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  Text(
                    'Humidity: ${latest.humidity.toStringAsFixed(0)}%',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                  Text(
                    'Conditions: ${latest.weatherDescription}',
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Square scan-frame overlay for the pH strip camera view â€” same visual
/// style (white L-shaped bracket corners, not a full border) as
/// qr_scan_screen.dart's _ScanFrame/_ScanFrameCornerPainter. Purely
/// decorative â€” has no bearing on _phSampleRegion, which samples a fixed
/// fraction of the actual captured image regardless of how this looks.
class _PhGuideBox extends StatelessWidget {
  const _PhGuideBox();

  static const double _size = 200;

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: _size,
        height: _size,
        child: CustomPaint(painter: _PhGuideBoxPainter()),
      ),
    );
  }
}

class _PhGuideBoxPainter extends CustomPainter {
  const _PhGuideBoxPainter();

  static const double _cornerLength = 28;
  static const double _strokeWidth = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = _strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Top-left
    canvas.drawLine(Offset.zero, const Offset(_cornerLength, 0), paint);
    canvas.drawLine(Offset.zero, const Offset(0, _cornerLength), paint);
    // Top-right
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width - _cornerLength, 0),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, _cornerLength),
      paint,
    );
    // Bottom-left
    canvas.drawLine(
      Offset(0, size.height),
      Offset(_cornerLength, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(0, size.height - _cornerLength),
      paint,
    );
    // Bottom-right
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - _cornerLength, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - _cornerLength),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PhGuideBoxPainter oldDelegate) => false;
}

/// Small read-only pill showing an AI-detected value, kept visually distinct
/// from (and never written into) the manual entry field next to it â€” the
/// officer sees the AI's suggestion but always types their own reading.
class _AiPredictionChip extends StatelessWidget {
  const _AiPredictionChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppSpacing.radiusPill),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome, size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Water-quality result card shown after a pH strip scan â€” colored
/// icon+label, the AI-predicted pH, confidence, and description. Confidence
/// and the italic disclaimer at the bottom exist specifically so this reads
/// as an estimate to verify, not a precise lab measurement.
class _PhResultCard extends StatelessWidget {
  const _PhResultCard({required this.result, required this.assessment});

  final PhDetectionResult result;
  final WaterQualityAssessment assessment;

  Color get _statusColor {
    switch (assessment.status) {
      case 'Safe':
        return Colors.green;
      case 'Caution':
        return Colors.orange;
      default:
        return Colors.red;
    }
  }

  String get _statusEmoji {
    switch (assessment.status) {
      case 'Safe':
        return 'ðŸŸ¢';
      case 'Caution':
        return 'ðŸŸ¡';
      default:
        return 'ðŸ”´';
    }
  }

  // Maps the underlying assessment.status data value ('Safe'/'Caution'/
  // 'Unsafe', also used for the Reading's waterQualityStatus field and the
  // color/emoji above) to its localized display text â€” display-only, the
  // stored value itself is untouched.
  String _localizedStatus(AppLocalizations l10n) {
    switch (assessment.status) {
      case 'Safe':
        return l10n.safe;
      case 'Caution':
        return l10n.caution;
      default:
        return l10n.unsafe;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_statusEmoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                _localizedStatus(l10n),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'AI Predicted pH: ${result.ph.toStringAsFixed(1)}',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Confidence: ${result.confidence.toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            assessment.description,
            style: const TextStyle(fontSize: 12, color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 4),
          Text(
            'Color-based estimate from a strip photo — affected by '
            'lighting and not a lab-grade measurement.',
            style: TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
