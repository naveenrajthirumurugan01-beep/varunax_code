import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Uploads captured gauge photos to Cloudinary, replacing Firebase Storage.
class CloudinaryService {
  static const String _uploadUrl =
      'https://api.cloudinary.com/v1_1/zpem1x8g/image/upload';
  static const String _uploadPreset = 'varuna_x_readings';

  /// Uploads [imageData] — either in-memory bytes ([Uint8List], for web) or
  /// a local file path ([String], for mobile/desktop) — and returns the
  /// resulting `secure_url`.
  Future<String> uploadImage(dynamic imageData) async {
    final request = http.MultipartRequest('POST', Uri.parse(_uploadUrl))
      ..fields['upload_preset'] = _uploadPreset;

    if (imageData is Uint8List) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageData,
          filename: 'reading.jpg',
        ),
      );
    } else if (imageData is String) {
      request.files.add(await http.MultipartFile.fromPath('file', imageData));
    } else {
      throw ArgumentError(
        'imageData must be Uint8List (web) or a file path String '
        '(mobile/desktop), got ${imageData.runtimeType}',
      );
    }

    final http.Response response;
    try {
      final streamedResponse = await request.send();
      response = await http.Response.fromStream(streamedResponse);
    } catch (e) {
      throw Exception('Cloudinary upload failed: could not reach server: $e');
    }

    if (response.statusCode != 200) {
      throw Exception(
        'Cloudinary upload failed (HTTP ${response.statusCode}): '
        '${response.body}',
      );
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Cloudinary upload failed: invalid response body: $e');
    }

    final secureUrl = body['secure_url'] as String?;
    if (secureUrl == null || secureUrl.isEmpty) {
      throw Exception(
        'Cloudinary upload failed: response had no secure_url: '
        '${response.body}',
      );
    }

    return secureUrl;
  }
}
