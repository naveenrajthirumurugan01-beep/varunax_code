import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;

/// Result of a color-based pH strip detection pass.
///
/// This is an estimate derived from the average color of a photographed
/// strip under normal phone-camera conditions — it is sensitive to ambient
/// lighting, white balance, and strip/brand variation, and is NOT a
/// substitute for a lab-grade or calibrated electronic pH meter.
/// [confidence] exists specifically to communicate that honestly: it
/// reflects how decisively the sampled color matched a single reference
/// point rather than sitting ambiguously between two, not an absolute
/// accuracy guarantee.
class PhDetectionResult {
  const PhDetectionResult({required this.ph, required this.confidence});

  /// Estimated pH, interpolated between the two closest reference colors.
  final double ph;

  /// 0-100.
  final double confidence;
}

/// Water quality classification for a given pH value.
class WaterQualityAssessment {
  const WaterQualityAssessment({
    required this.status,
    required this.description,
  });

  /// "Safe", "Caution", or "Unsafe".
  final String status;
  final String description;
}

class _PhReference {
  const _PhReference(this.ph, this.r, this.g, this.b);

  final int ph;
  final int r;
  final int g;
  final int b;
}

/// Estimates pH from a photographed color-change strip by comparing the
/// average color under a guide-box region against a reference color table
/// approximating standard universal-indicator strip behavior, then
/// classifies the result against typical safe ranges for aquatic life.
///
/// This is color-based estimation from a phone camera photo — it is
/// sensitive to ambient lighting, white balance, and strip/brand variation,
/// and is NOT a substitute for a lab-grade or calibrated electronic pH
/// meter. Callers must surface [PhDetectionResult.confidence] to the
/// officer (and fall back to manual entry when it's low) rather than
/// presenting a single number with a false sense of precision.
class PhDetectionService {
  // Approximate standard universal-indicator strip colors at each integer
  // pH 0-14: deep red (strongly acidic) -> red-orange -> orange -> yellow
  // -> yellow-green (~7, neutral) -> green -> blue-green -> blue ->
  // blue-violet -> deep purple (strongly alkaline).
  static const List<_PhReference> _referenceTable = [
    _PhReference(0, 255, 0, 0),
    _PhReference(1, 255, 20, 20),
    _PhReference(2, 255, 60, 0),
    _PhReference(3, 255, 100, 0),
    _PhReference(4, 255, 140, 0),
    _PhReference(5, 255, 180, 0),
    _PhReference(6, 255, 220, 0),
    _PhReference(7, 200, 220, 60),
    _PhReference(8, 100, 200, 100),
    _PhReference(9, 0, 180, 150),
    _PhReference(10, 0, 120, 200),
    _PhReference(11, 0, 80, 220),
    _PhReference(12, 60, 40, 200),
    _PhReference(13, 100, 20, 180),
    _PhReference(14, 120, 0, 150),
  ];

  /// Samples the average color under [sampleRegion] — a fractional box
  /// (left/top/right/bottom each in `[0, 1]`, relative to the full image's
  /// width/height) matching wherever the on-screen guide box is centered as
  /// a fraction of the (non-cropped) camera preview — in the photo at
  /// [imageData] (a file path), and estimates pH by comparing that color
  /// against [_referenceTable] via Euclidean RGB distance, interpolating
  /// between the two closest reference points.
  ///
  /// Returns `null` if detection fails for any reason (unreadable file,
  /// degenerate sample region, unsupported platform, etc) — callers must
  /// fall back to manual entry.
  Future<PhDetectionResult?> detectPh(
    dynamic imageData,
    Rect sampleRegion,
  ) async {
    // package:image + dart:io file reads have no meaningful web
    // implementation for this app — same kIsWeb guard used by
    // AiDetectionService/SegmentationService for the other capture-time
    // detectors — skip rather than let it throw.
    if (kIsWeb) return null;

    try {
      final imagePath = imageData as String;
      final fileBytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return null;

      final left = (sampleRegion.left.clamp(0.0, 1.0) * decoded.width).round();
      final top = (sampleRegion.top.clamp(0.0, 1.0) * decoded.height).round();
      final right = (sampleRegion.right.clamp(0.0, 1.0) * decoded.width)
          .round();
      final bottom = (sampleRegion.bottom.clamp(0.0, 1.0) * decoded.height)
          .round();
      if (right <= left || bottom <= top) return null;

      double sumR = 0, sumG = 0, sumB = 0;
      var count = 0;
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          final pixel = decoded.getPixel(x, y);
          sumR += pixel.r;
          sumG += pixel.g;
          sumB += pixel.b;
          count++;
        }
      }
      if (count == 0) return null;

      final avgR = sumR / count;
      final avgG = sumG / count;
      final avgB = sumB / count;

      final distances = _referenceTable
          .map(
            (ref) => _euclideanDistance(avgR, avgG, avgB, ref.r, ref.g, ref.b),
          )
          .toList();

      var bestIndex = 0;
      for (var i = 1; i < distances.length; i++) {
        if (distances[i] < distances[bestIndex]) bestIndex = i;
      }

      final leftNeighbor = bestIndex > 0 ? bestIndex - 1 : null;
      final rightNeighbor = bestIndex < distances.length - 1
          ? bestIndex + 1
          : null;

      int? otherIndex;
      if (leftNeighbor != null && rightNeighbor != null) {
        otherIndex = distances[leftNeighbor] <= distances[rightNeighbor]
            ? leftNeighbor
            : rightNeighbor;
      } else {
        otherIndex = leftNeighbor ?? rightNeighbor;
      }

      final bestDistance = distances[bestIndex];

      final double ph;
      final double confidence;
      if (otherIndex == null) {
        // Degenerate single-entry table — no interpolation possible.
        ph = _referenceTable[bestIndex].ph.toDouble();
        confidence = bestDistance == 0 ? 100 : 0;
      } else {
        final otherDistance = distances[otherIndex];
        final total = bestDistance + otherDistance;
        // Inverse-distance weighting: the closer reference point pulls the
        // interpolated pH (and the confidence score) toward itself.
        final bestWeight = total == 0 ? 1.0 : otherDistance / total;
        final otherWeight = total == 0 ? 0.0 : bestDistance / total;
        ph =
            _referenceTable[bestIndex].ph * bestWeight +
            _referenceTable[otherIndex].ph * otherWeight;
        // 100% when the sampled color sits exactly on one reference point
        // (near-exact match); 0% when it's exactly midway between two
        // references (maximally ambiguous, could plausibly be either pH).
        confidence = total == 0
            ? 100
            : ((otherDistance - bestDistance) / total) * 100;
      }

      return PhDetectionResult(ph: ph, confidence: confidence.clamp(0, 100));
    } catch (_) {
      return null;
    }
  }

  /// Classifies [ph] against typical safe ranges for aquatic life.
  WaterQualityAssessment classifyWaterQuality(double ph) {
    if (ph >= 6.5 && ph <= 8.5) {
      return const WaterQualityAssessment(
        status: 'Safe',
        description: 'Suitable for aquatic life',
      );
    }
    if ((ph >= 5.5 && ph < 6.5) || (ph > 8.5 && ph <= 9.5)) {
      return const WaterQualityAssessment(
        status: 'Caution',
        description: 'Slightly acidic/alkaline, monitor',
      );
    }
    return const WaterQualityAssessment(
      status: 'Unsafe',
      description: 'Highly acidic/alkaline water',
    );
  }

  double _euclideanDistance(
    double r1,
    double g1,
    double b1,
    num r2,
    num g2,
    num b2,
  ) {
    final dr = r1 - r2;
    final dg = g1 - g2;
    final db = b1 - b2;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }
}
