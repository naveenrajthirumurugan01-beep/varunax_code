import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

/// Result of a water-line segmentation pass over a captured gauge photo.
class SegmentationResult {
  const SegmentationResult({required this.waterLinePercent});

  /// Estimated position of the water line as a percentage of frame height
  /// (0% = top of frame, 100% = bottom of frame).
  final double waterLinePercent;
}

/// Runs the bundled water-segmentation ONNX model over a captured gauge
/// photo to estimate where the water line sits in the frame.
///
/// This is a *suggestion* only, exactly like [AiDetectionService]'s OCR
/// reading — callers must let the officer verify/edit the value, never
/// treat it as ground truth.
class SegmentationService {
  static const _modelAsset = 'assets/models/water_segmentation.onnx';
  static const _inputSize = 256;

  OrtSession? _session;

  Future<OrtSession> _loadSession() async {
    final existing = _session;
    if (existing != null) return existing;

    OrtEnv.instance.init();
    final rawAsset = await rootBundle.load(_modelAsset);
    final bytes = rawAsset.buffer.asUint8List();
    final sessionOptions = OrtSessionOptions();
    final session = OrtSession.fromBuffer(bytes, sessionOptions);
    _session = session;
    return session;
  }

  /// Returns the estimated water-line position in [imageData] (a file path),
  /// or `null` if detection fails for any reason (blurry photo, model load
  /// failure, no water pixels found, etc). Callers must treat the result as
  /// a suggestion, never as ground truth.
  Future<SegmentationResult?> detectWaterLevel(dynamic imageData) async {
    // onnxruntime's Flutter plugin has no web implementation, and dart:io
    // File access (used below to read the photo) isn't available on web
    // either — skip detection entirely rather than let it throw, matching
    // the same pattern AiDetectionService uses for its OCR call.
    if (kIsWeb) return null;

    try {
      final imagePath = imageData as String;
      final fileBytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return null;

      final resized = img.copyResize(
        decoded,
        width: _inputSize,
        height: _inputSize,
        interpolation: img.Interpolation.linear,
      );

      // CHW layout, normalized to [0,1] — same preprocessing used when the
      // model was trained/exported.
      final input = Float32List(3 * _inputSize * _inputSize);
      var i = 0;
      for (var c = 0; c < 3; c++) {
        for (var y = 0; y < _inputSize; y++) {
          for (var x = 0; x < _inputSize; x++) {
            final pixel = resized.getPixel(x, y);
            final channelValue = switch (c) {
              0 => pixel.r,
              1 => pixel.g,
              _ => pixel.b,
            };
            input[i++] = channelValue / 255.0;
          }
        }
      }

      final session = await _loadSession();
      final inputOrt = OrtValueTensor.createTensorWithDataList(input, [
        1,
        3,
        _inputSize,
        _inputSize,
      ]);
      final runOptions = OrtRunOptions();

      try {
        final inputName = session.inputNames.isNotEmpty ? session.inputNames.first : 'input';
        final outputs = await session.runAsync(runOptions, {
          inputName: inputOrt,
        });
        if (outputs == null || outputs.isEmpty) return null;

        final outputValue = outputs.first?.value;
        for (final element in outputs) {
          element?.release();
        }
        if (outputValue == null) return null;

        // Output tensor shape is (1, 1, 256, 256) raw logits — unwrap the
        // batch/channel dims to get a 256-row list of 256-column rows.
        final logits = (outputValue as List)[0][0] as List;

        // Binary water mask via sigmoid(logit) > 0.5, equivalent to
        // logit > 0. Require at least 25 pixels (approx 10% of the 256 width) 
        // in a row to be classified as water to prevent isolated noise or 
        // reflections from triggering false high water readings.
        int? waterLineRow;
        for (var y = 0; y < _inputSize; y++) {
          final row = logits[y] as List;
          final waterPixelCount = row.where((v) => (v as num) > 0).length;
          if (waterPixelCount >= 25) {
            waterLineRow = y;
            break;
          }
        }
        if (waterLineRow == null) return null;

        // NOTE: this is a relative visual estimate of where the water line
        // falls within the photographed frame, expressed as a percentage of
        // frame height. It is NOT an absolute calibrated water level in
        // meters — there is no per-site mapping yet from pixel row to real
        // gauge height/elevation, so it cannot be compared across sites or
        // substituted for the physical gauge reading.
        final percent = (waterLineRow / _inputSize) * 100;
        return SegmentationResult(waterLinePercent: percent);
      } finally {
        inputOrt.release();
        runOptions.release();
      }
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    // The session's native side is never initialized on web (see the
    // kIsWeb guard in detectWaterLevel above), so releasing it there would
    // be a no-op at best — only release on platforms where it runs.
    if (!kIsWeb) {
      _session?.release();
    }
  }
}
