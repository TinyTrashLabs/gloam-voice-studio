// CSherpaOnnx exists ONLY for the header: it vendors sherpa-onnx's c-api.h
// (k2-fsa/sherpa-onnx v1.13.4, Apache-2.0) so Swift gets the exact C struct
// layouts — SherpaOnnxOfflineTtsConfig and friends — without linking anything.
//
// The library itself is NOT linked at build time. Prebuilt sherpa-onnx dylibs
// are fetched by scripts/fetch-pocket-tts.sh and dlopen'd at runtime
// (PocketSpeechModel.swift), because SwiftPM offers no way to link a
// downloaded, gitignored dylib without unsafeFlags — and unsafeFlags would
// make EngineKit unconsumable as a dependency (the iOS app consumes it).
//
// SwiftPM requires at least one compiled source in a C target; this is it.
void csherpa_onnx_header_only(void) {}
