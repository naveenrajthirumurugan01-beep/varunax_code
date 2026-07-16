import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Runs on-device OCR over a captured gauge photo and tries to guess the
/// water level reading from any numeric text found in the image.
///
/// This is a *suggestion* only — callers must let the officer verify/edit
/// the value, never treat it as ground truth.
class AiDetectionService {
  static final RegExp _numericReadingPattern = RegExp(r'^\d{1,2}(\.\d+)?$');

  final TextRecognizer _textRecognizer;

  AiDetectionService({TextRecognizer? textRecognizer})
    : _textRecognizer =
          textRecognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  /// Returns the best-guess numeric gauge reading found in [imagePath], or
  /// `null` if detection fails or nothing that looks like a reading is
  /// found (blurry photo, no visible gauge markings, etc).
  Future<double?> detectWaterLevel(String imagePath) async {
    // google_mlkit_text_recognition has no web platform implementation, and
    // InputImage.fromFilePath relies on dart:io File access that isn't
    // available on web either. Skip detection rather than let it throw.
    if (kIsWeb) return null;

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await _textRecognizer.processImage(inputImage);

      final candidates = <double>[];
      for (final block in recognizedText.blocks) {
        for (final line in block.lines) {
          final text = line.text.trim();
          if (_numericReadingPattern.hasMatch(text)) {
            final value = double.tryParse(text);
            if (value != null) {
              candidates.add(value);
            }
          }
        }
      }

      if (candidates.isEmpty) return null;

      // Prefer the candidate with a decimal point — gauge readings are
      // typically reported to sub-meter precision — otherwise take the
      // first match.
      candidates.sort((a, b) {
        final aHasDecimal = a != a.truncateToDouble();
        final bHasDecimal = b != b.truncateToDouble();
        if (aHasDecimal == bHasDecimal) return 0;
        return aHasDecimal ? -1 : 1;
      });

      return candidates.first;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    // The recognizer's native side is never initialized on web (see the
    // kIsWeb guard in detectWaterLevel above), so closing it there throws
    // MissingPluginException — only close it on platforms where it runs.
    if (!kIsWeb) {
      _textRecognizer.close();
    }
  }
}
