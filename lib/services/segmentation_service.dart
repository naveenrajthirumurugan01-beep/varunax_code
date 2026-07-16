// Conditional export: use the real onnxruntime-backed implementation by
// default, and swap in the web stub when compiling for web.
//
// dart.library.js_interop is only available when compiling for a web target
// (js/wasm) — it's absent on the native Dart VM/AOT — so it's the correct
// signal to detect "is this a web build", now that dart.library.html is
// deprecated and unsupported under dart2wasm. Getting the branches backwards
// here (defaulting to the web stub and only swapping in the io version for
// web) would reintroduce the exact FFI-on-web compile failure this file
// exists to avoid.
export 'segmentation_service_io.dart'
    if (dart.library.js_interop) 'segmentation_service_web.dart';
