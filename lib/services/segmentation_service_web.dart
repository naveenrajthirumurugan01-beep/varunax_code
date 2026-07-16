/// Web stub for [SegmentationService].
///
/// onnxruntime (used by the real implementation in
/// segmentation_service_io.dart) is FFI-based, and Flutter Web cannot
/// compile FFI code at all — not even code gated behind a `kIsWeb` runtime
/// check, since the failure happens at compile time. This stub has no
/// dependency on onnxruntime or any other FFI-based package, so it's safe
/// to include in the web build; segmentation_service.dart picks whichever
/// file gets compiled in via a conditional export.
class SegmentationResult {
  const SegmentationResult({required this.waterLinePercent});

  final double waterLinePercent;
}

class SegmentationService {
  Future<SegmentationResult?> detectWaterLevel(dynamic imageData) async {
    return null;
  }

  void dispose() {}
}
