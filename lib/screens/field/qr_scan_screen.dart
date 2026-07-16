import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../models/site_model.dart';
import 'capture_screen.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, required this.site});

  final Site site;

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
    _verifyScannedCode(rawValue);
  }

  Future<void> _verifyScannedCode(String qrCode) async {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    if (qrCode != widget.site.qrCode) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage =
            "This QR code doesn't match ${widget.site.name}. Please scan "
            "the correct site's code.";
      });
      return;
    }

    await _controller.stop();

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => CaptureScreen(site: widget.site),
      ),
    );
  }

  void _retry() {
    setState(() {
      _errorMessage = null;
      _lastAttemptedValue = null;
    });
  }

  void _useManualEntry() {
    // The officer already chose this site from the list before reaching
    // this screen, so the fallback skips the QR check entirely rather than
    // showing a second site picker.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => CaptureScreen(site: widget.site),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Site QR Code')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              'Scan QR code for: ${widget.site.name}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          Expanded(
            child: Stack(
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
                    bottom: 16,
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
              ],
            ),
          ),
          // Deliberately understated — an exception path for a damaged or
          // missing QR code, not an equal alternative to scanning.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextButton(
                onPressed: _useManualEntry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey.shade600,
                ),
                child: const Text(
                  'QR code damaged or missing? Use manual entry',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
