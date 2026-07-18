import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as img;

class ImageQualityResult {
  final bool isBlurry;
  final bool isDark;
  final double averageLuminance;
  final double gradientMagnitude;

  ImageQualityResult({
    required this.isBlurry,
    required this.isDark,
    required this.averageLuminance,
    required this.gradientMagnitude,
  });
}

class ImageQualityService {
  /// Analyzes the photo at [imagePath] for brightness and blurriness.
  Future<ImageQualityResult> analyzeImage(String imagePath) async {
    if (kIsWeb) {
      return ImageQualityResult(
        isBlurry: false,
        isDark: false,
        averageLuminance: 128.0,
        gradientMagnitude: 500.0,
      );
    }

    try {
      final fileBytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) {
        return ImageQualityResult(
          isBlurry: false,
          isDark: false,
          averageLuminance: 128.0,
          gradientMagnitude: 500.0,
        );
      }

      // To run quickly on mobile, downsample the image first to 128x128
      final smallImg = img.copyResize(decoded, width: 128, height: 128);

      double totalLuminance = 0;
      final pixelCount = smallImg.width * smallImg.height;

      // Compute average luminance: Luminance = 0.299*R + 0.587*G + 0.114*B
      for (var y = 0; y < smallImg.height; y++) {
        for (var x = 0; x < smallImg.width; x++) {
          final p = smallImg.getPixel(x, y);
          final r = p.r;
          final g = p.g;
          final b = p.b;
          final lum = 0.299 * r + 0.587 * g + 0.114 * b;
          totalLuminance += lum;
        }
      }
      final avgLuminance = totalLuminance / pixelCount;

      // Compute horizontal and vertical differences to check for sharp edges
      double totalDiff = 0;
      var edgesCount = 0;

      for (var y = 0; y < smallImg.height - 1; y++) {
        for (var x = 0; x < smallImg.width - 1; x++) {
          final p = smallImg.getPixel(x, y);
          final pRight = smallImg.getPixel(x + 1, y);
          final pDown = smallImg.getPixel(x, y + 1);

          final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          final lumRight = 0.299 * pRight.r + 0.587 * pRight.g + 0.114 * pRight.b;
          final lumDown = 0.299 * pDown.r + 0.587 * pDown.g + 0.114 * pDown.b;

          final dx = lumRight - lum;
          final dy = lumDown - lum;

          // Gradient magnitude
          final grad = dx.abs() + dy.abs();
          totalDiff += grad;
          edgesCount++;
        }
      }

      final avgDiff = edgesCount > 0 ? (totalDiff / edgesCount) : 0.0;

      // Darkness threshold: avgLuminance < 40 (out of 255)
      // Blurry threshold: avgDiff < 12.0 (indicates very soft, indistinct transitions)
      final isDark = avgLuminance < 40.0;
      final isBlurry = avgDiff < 12.0;

      return ImageQualityResult(
        isBlurry: isBlurry,
        isDark: isDark,
        averageLuminance: avgLuminance,
        gradientMagnitude: avgDiff,
      );
    } catch (_) {
      return ImageQualityResult(
        isBlurry: false,
        isDark: false,
        averageLuminance: 128.0,
        gradientMagnitude: 500.0,
      );
    }
  }
}
