// COnnxRuntime exists ONLY for the header: it vendors ONNX Runtime's
// onnxruntime_c_api.h (v1.20, MIT — the exact header shipped inside the
// onnxruntime-swift-package-manager binary artifact this package already
// links) so Swift gets the C API function table (OrtApi) that the
// Objective-C surface does not re-export.
//
// Why the C API at all: LuxOnnxEngine needs memory-lifecycle control that
// ORTSessionOptions (ObjC) does not expose — DisableCpuMemArena,
// DisableMemPattern, RunOptions arena shrinkage. Those knobs are the
// difference between a 4.4 GB and a sub-1 GB peak on a 12 s render, and the
// iOS ports (gloam-dj, gloam-voice-studio-ios) already drive ORT through the
// C API, so this also makes the macOS mirror structurally identical.
//
// Nothing new is linked: OrtGetApiBase comes from the same
// onnxruntime.xcframework the "onnxruntime" SwiftPM product already links on
// macOS. On iOS builds of EngineKit (gloam-dj consumes it as a local
// package) the header compiles but no symbol is referenced — LuxEngine is
// #if os(macOS).
//
// SwiftPM requires at least one compiled source in a C target; this is it.
void connxruntime_header_only(void) {}
