import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';
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
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(controller: _controller, onDetect: _handleDetect),
                // Dims the live camera feed so the header/frame read clearly
                // on top of it.
                Container(color: Colors.black.withValues(alpha: 0.35)),
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        _CircularIconButton(
                          icon: Icons.arrow_back,
                          // Same pop the screen's default back arrow already
                          // performed — just restyled as a circular button.
                          onTap: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 16),
                        const Text(
                          'VARUNA X',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Center(child: _ScanFrame()),
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
                        borderRadius: BorderRadius.circular(
                          AppSpacing.radiusStandard,
                        ),
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
          // White card with rounded top corners, holding the scan
          // instructions and the manual-entry fallback.
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(AppSpacing.radiusCard),
                topRight: Radius.circular(AppSpacing.radiusCard),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: AppColors.secondaryContainer,
                      child: const Icon(
                        Icons.qr_code,
                        color: AppColors.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Scan QR Code',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(color: const Color(0xFF000000)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Position the code inside the frame to verify '
                      'equipment at ${widget.site.name}.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Deliberately understated — an exception path for a
                    // damaged or missing QR code, not an equal alternative
                    // to scanning.
                    TextButton(
                      onPressed: _useManualEntry,
                      child: const Text('Enter code manually instead'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircularIconButton extends StatelessWidget {
  const _CircularIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: AppColors.onSurface, size: 20),
        ),
      ),
    );
  }
}

/// Square scan frame with rounded bracket corners (not a full border),
/// overlaid on the dimmed camera feed. Purely decorative — has no bearing on
/// where MobileScanner actually looks for a code.
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  static const double _size = 240;

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: _size,
      height: _size,
      child: CustomPaint(painter: _ScanFrameCornerPainter()),
    );
  }
}

class _ScanFrameCornerPainter extends CustomPainter {
  const _ScanFrameCornerPainter();

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
  bool shouldRepaint(covariant _ScanFrameCornerPainter oldDelegate) => false;
}
