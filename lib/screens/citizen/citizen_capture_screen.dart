import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/theme.dart';
import '../../models/citizen_report_model.dart';
import '../../services/auth_service.dart';
import '../../services/cloudinary_service.dart';
import '../../services/location_service.dart';

const _waterConditions = ['Normal', 'Rising', 'Flooding', 'Receding'];
const _descriptionMaxLength = 200;

enum _CitizenCaptureStage {
  checkingLocation,
  outsideZone,
  insideZone,
  camera,
  preview,
}

/// Citizen-reporter equivalent of the field officer's CaptureScreen — much
/// simpler by design: no QR scan, no gauge reading, no pH strip. Just a
/// live photo, a water-condition dropdown, and an optional description,
/// geofenced to the citizen's own registered area rather than a formal
/// monitoring [Site].
class CitizenCaptureScreen extends StatefulWidget {
  const CitizenCaptureScreen({
    super.key,
    required this.registeredZone,
    required this.registeredZoneRadius,
    required this.registeredZoneLatitude,
    required this.registeredZoneLongitude,
  });

  final String registeredZone;
  final double registeredZoneRadius;
  // Null when the citizen's account has no geofence anchor yet (e.g. GPS
  // wasn't available at registration time) — the geofence check is skipped
  // entirely in that case rather than permanently locking the account out
  // of reporting.
  final double? registeredZoneLatitude;
  final double? registeredZoneLongitude;

  @override
  State<CitizenCaptureScreen> createState() => _CitizenCaptureScreenState();
}

class _CitizenCaptureScreenState extends State<CitizenCaptureScreen> {
  final _locationService = LocationService();
  final _descriptionController = TextEditingController();

  _CitizenCaptureStage _stage = _CitizenCaptureStage.checkingLocation;
  String? _errorMessage;
  double? _userLatitude;
  double? _userLongitude;
  double? _distanceMeters;

  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;
  XFile? _capturedPhoto;
  Uint8List? _capturedPhotoBytes;
  bool _isSaving = false;

  String _waterCondition = _waterConditions.first;

  bool get _hasZoneAnchor =>
      widget.registeredZoneLatitude != null &&
      widget.registeredZoneLongitude != null;

  bool get _canSubmit =>
      _capturedPhoto != null && _userLatitude != null && _userLongitude != null;

  @override
  void initState() {
    super.initState();
    _checkLocation();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _checkLocation() async {
    setState(() {
      _stage = _CitizenCaptureStage.checkingLocation;
      _errorMessage = null;
    });

    try {
      final position = await _locationService.getCurrentLocation();

      if (!mounted) return;

      if (!_hasZoneAnchor) {
        setState(() {
          _userLatitude = position.latitude;
          _userLongitude = position.longitude;
          _distanceMeters = null;
          _stage = _CitizenCaptureStage.insideZone;
        });
        return;
      }

      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        widget.registeredZoneLatitude!,
        widget.registeredZoneLongitude!,
      );
      final withinZone = _locationService.isWithinGeofence(
        position.latitude,
        position.longitude,
        widget.registeredZoneLatitude!,
        widget.registeredZoneLongitude!,
        widget.registeredZoneRadius,
      );

      setState(() {
        _userLatitude = position.latitude;
        _userLongitude = position.longitude;
        _distanceMeters = distance;
        _stage = withinZone
            ? _CitizenCaptureStage.insideZone
            : _CitizenCaptureStage.outsideZone;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _stage = _CitizenCaptureStage.outsideZone;
      });
    }
  }

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
        _stage = _CitizenCaptureStage.camera;
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
        _stage = _CitizenCaptureStage.preview;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to capture photo: $e';
      });
    }
  }

  void _retake() {
    setState(() {
      _capturedPhoto = null;
      _capturedPhotoBytes = null;
      _stage = _CitizenCaptureStage.camera;
    });
  }

  Future<void> _submitReport() async {
    final photo = _capturedPhoto;
    if (photo == null || _userLatitude == null || _userLongitude == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
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

      final reportRef = FirebaseFirestore.instance
          .collection('citizen_reports')
          .doc();
      final report = CitizenReport(
        reportId: reportRef.id,
        submittedBy: AuthService().currentUser?.uid ?? 'unknown',
        submitterZone: widget.registeredZone,
        timestamp: DateTime.now(),
        photoUrl: photoUrl,
        waterCondition: _waterCondition,
        description: _descriptionController.text.trim(),
        latitude: _userLatitude!,
        longitude: _userLongitude!,
        verificationStatus: 'pending',
      );

      await reportRef.set(report.toMap());

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const _CitizenReportSuccessScreen(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to submit report: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Report River Condition'),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_stage) {
      case _CitizenCaptureStage.camera:
        return _buildCameraPreview();
      case _CitizenCaptureStage.preview:
        return _buildPhotoPreview();
      case _CitizenCaptureStage.checkingLocation:
      case _CitizenCaptureStage.outsideZone:
      case _CitizenCaptureStage.insideZone:
        return _buildForm();
    }
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.location_on, color: AppColors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '📍 Reporting from ${widget.registeredZone}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildZoneSection(),
        ],
      ),
    );
  }

  Widget _buildZoneSection() {
    switch (_stage) {
      case _CitizenCaptureStage.checkingLocation:
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
      case _CitizenCaptureStage.outsideZone:
        return _buildOutsideZone();
      case _CitizenCaptureStage.insideZone:
        return _buildInsideZone();
      case _CitizenCaptureStage.camera:
      case _CitizenCaptureStage.preview:
        return const SizedBox.shrink();
    }
  }

  Widget _buildOutsideZone() {
    final distance = _distanceMeters;
    final message =
        _errorMessage ??
        (distance != null
            ? 'You can only report from your registered area '
                  '(${widget.registeredZone}). You are '
                  '${distance.toStringAsFixed(0)}m away.'
            : 'You can only report from your registered area '
                  '(${widget.registeredZone}).');

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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF1A1A1A)),
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

  Widget _buildInsideZone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_hasZoneAnchor) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(AppSpacing.radiusStandard),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange.shade700, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Zone verification unavailable — submitting without '
                    'location check',
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ] else
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
                    'Within your registered area',
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
            style: const TextStyle(color: AppColors.error),
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
                  final size = constraints.biggest;
                  var cameraAspectRatio = controller.value.aspectRatio;
                  if (MediaQuery.of(context).orientation ==
                      Orientation.portrait) {
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 300, child: photoPreview),
          const SizedBox(height: 16),
          Text(
            'Water Condition',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: const Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _waterCondition,
            items: [
              for (final condition in _waterConditions)
                DropdownMenuItem(
                  value: condition,
                  child: Text(
                    condition,
                    style: const TextStyle(color: Color(0xFF1A1A1A)),
                  ),
                ),
            ],
            onChanged: _isSaving
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _waterCondition = value);
                  },
          ),
          const SizedBox(height: 16),
          Text(
            'Describe what you see (optional)',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: const Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descriptionController,
            enabled: !_isSaving,
            maxLength: _descriptionMaxLength,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'e.g. Water level rising near the footbridge',
            ),
          ),
          const SizedBox(height: 8),
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
                      'Submitting report...',
                      style: TextStyle(color: Color(0xFF1A1A1A)),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton(
                      onPressed: _retake,
                      child: const Text('Retake'),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _canSubmit ? _submitReport : null,
                      icon: const Icon(Icons.upload),
                      label: const Text('Submit Report'),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}

class _CitizenReportSuccessScreen extends StatelessWidget {
  const _CitizenReportSuccessScreen();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Report Submitted')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.check_circle,
                color: Colors.green,
                size: 72,
              ),
              const SizedBox(height: 16),
              Text(
                'Thank you! Your report will be reviewed before being '
                'shared with authorities.',
                textAlign: TextAlign.center,
                style: textTheme.headlineLarge?.copyWith(
                  color: const Color(0xFF000000),
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
