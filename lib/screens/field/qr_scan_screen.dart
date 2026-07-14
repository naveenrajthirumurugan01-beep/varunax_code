import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../models/site_model.dart';
import 'capture_screen.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController();

  bool _isProcessing = false;
  String? _errorMessage;
  String? _lastAttemptedValue;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_isProcessing) return;

    final rawValue = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue
        : null;
    if (rawValue == null || rawValue.isEmpty) return;

    if (rawValue == _lastAttemptedValue && _errorMessage != null) return;

    _lastAttemptedValue = rawValue;
    _lookupSite(rawValue);
  }

  Future<void> _lookupSite(String qrCode) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final query = await FirebaseFirestore.instance
          .collection('sites')
          .where('qrCode', isEqualTo: qrCode)
          .limit(1)
          .get();

      if (!mounted) return;

      if (query.docs.isEmpty) {
        setState(() {
          _isProcessing = false;
          _errorMessage = "QR code doesn't match any known site";
        });
        return;
      }

      final doc = query.docs.first;
      final site = Site.fromMap({...doc.data(), 'siteId': doc.id});

      await _controller.stop();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => CaptureScreen(site: site)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Failed to look up site: $e';
      });
    }
  }

  void _retry() {
    setState(() {
      _errorMessage = null;
      _lastAttemptedValue = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Site QR Code')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _handleDetect),
          if (_isProcessing)
            const ColoredBox(
              color: Colors.black54,
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_errorMessage != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 96,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Enter site manually instead'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
