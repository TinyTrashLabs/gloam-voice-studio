// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gloam-voice-studio",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EngineKit", targets: ["EngineKit"]),
        .library(name: "StudioKit", targets: ["StudioKit"]),
        .library(name: "SpeechKit", targets: ["SpeechKit"]),
    ],
    dependencies: [
        // Vendored fork of Blaizzy/mlx-audio-swift with the Chatterbox regular-model
        // reference-parity fixes (rounds 1–3): dropped S3Gen attn biases, RNG clobber,
        // eval-mode, S3Tokenizer rotary, ODE steps, stft center, HiFT lrelu slope, the
        // torchaudio-matching 16k/24k resampler, and fresh flow noise; plus the
        // T3 token cap on the reference-clip path so a high-exaggeration line can't
        // run away past EOS (PR #3). See TinyTrashLabs/mlx-audio-swift and
        // docs/chatterbox-quality-todo.md.
        // Pinned to the merge commit of TinyTrashLabs/mlx-audio-swift#5 (merged into
        // main), which adds the native-MLX SuperTonic 3 model (model_type "supertonic").
        // Bumped 2026-08-23 to the paced-vocoder-decode merge (our #6): the Qwen
        // batch path now decodes in 50-token passes with 20ms gaps BY DEFAULT —
        // the end-of-generation 24s-per-pass Metal bursts audibly glitched any
        // co-resident audio playback (gloam-dj #297; A/B'd 3/3 crackle → 3/3
        // clean). Tunable via qwenDecodeChunkTokens/qwenDecodePaceMs defaults
        // or MLX_AUDIO_QWEN_DECODE_* env; explicit paceMs=0 disables.
        // Bumped 2026-08-25 to the custom-style-path merge (our #7): supertonic
        // accepts an absolute {style_ttl, style_dp} .json path as `voice`, so
        // .gvoice packs' baked supertonic renditions actually drive synthesis.
        .package(
            url: "https://github.com/TinyTrashLabs/mlx-audio-swift.git",
            revision: "a987e6a517bcf29f474692967919df6c289c551d"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        // Pinned to the commit that merges upstream #390 (the Gemma4 VLM
        // kvSharedOnly fix so QAT checkpoints — gemma-4-e2b/e4b — load; our own
        // #402 was closed as a duplicate in favor of #390). No tagged release
        // includes it yet, so pin the exact commit rather than wait; repin to a
        // real release once ml-explore/mlx-swift-lm cuts one past 2026-07-10.
        // mlx-audio-swift's own mlx-swift-lm dependency (above) is pinned to the
        // same commit (TinyTrashLabs/mlx-audio-swift#4) so both chains agree —
        // otherwise SwiftPM sees two remotes for one package identity.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git",
                revision: "09deb8c4e9056fcd76b60718bb50325d1730572b"),
        // HuggingFace Hub client + Tokenizers — back the mlx-swift-lm #huggingFace…
        // macros (mlx-swift-lm 3.x ships the integration as macros the consumer
        // wires to concrete impls, not a bundled dependency). Both are already in
        // the resolved graph transitively (via mlx-audio-swift / WhisperKit).
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMinor(from: "0.9.0")),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.3.3")),
        // Pin swift-jinja below 2.4.0. 2.4.0 re-keyed `Jinja.Value.object` from
        // `[String: Value]` to `[ObjectKey: Value]`, which swift-transformers 1.3.3's
        // Config.swift does not compile against (String vs ObjectKey). Our own lock
        // and the macOS app hold 2.3.6, but a fresh consumer resolve (the iOS app)
        // grabbed 2.4.0 and broke the build. Constrain here so EVERY consumer's
        // resolution lands on the compatible 2.3.6.
        .package(url: "https://github.com/huggingface/swift-jinja.git", "2.0.0" ..< "2.4.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.19")),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", .upToNextMajor(from: "2.5.0")),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMajor(from: "1.0.0")),
        // ONNX Runtime, so LuxTTS can run the SAME int8 graphs the iOS apps ship
        // (gloam-voice-studio-ios, gloam-dj) alongside this repo's native MLX
        // implementation. Without it there is no way to A/B the two on one
        // machine, and every quality question about the iOS port has to be
        // argued from measurements instead of listened to.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
                 .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        // Header-only: vendors sherpa-onnx's c-api.h for the C struct layouts.
        // The dylib is fetched by scripts/fetch-pocket-tts.sh and dlopen'd at
        // runtime — see Sources/CSherpaOnnx/shim.c for why it isn't linked.
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx"
        ),
        // Header-only: vendors ONNX Runtime's onnxruntime_c_api.h so
        // LuxOnnxEngine can reach the C API's memory-lifecycle knobs
        // (DisableCpuMemArena etc.) that the ObjC surface hides. The symbols
        // come from the same onnxruntime.xcframework linked below — see
        // Sources/COnnxRuntime/shim.c.
        .target(
            name: "COnnxRuntime",
            path: "Sources/COnnxRuntime"
        ),
        .target(
            name: "EngineKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                // MoE Gemma-4 (gemma-4-26b-a4b) is a `Gemma4ForConditionalGeneration`
                // whose expert/router text stack is implemented only in the VLM
                // factory — the LLM factory's dense Gemma4 dies on its MoE weights.
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                // Linked (though used transitively via Tokenizers) so the swift-jinja
                // < 2.4.0 constraint above is RETAINED when EngineKit is consumed as a
                // dependency. SPM prunes a non-root package's unused dependency
                // declarations, which silently dropped the pin for the iOS app and let
                // jinja float to the incompatible 2.4.0.
                .product(name: "Jinja", package: "swift-jinja"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                // On-device ASR (AppleTranscriber, zero downloads/network) backs
                // LuxTTS's generate-then-verify retry loop — see LuxOutputVerifier.swift.
                "SpeechKit",
                // The ORT C API, for LuxOnnxEngine — the int8 ONNX LuxTTS path
                // that mirrors what iOS ships, so both can be compared here.
                // macOS ONLY. gloam-dj consumes EngineKit as a local package and
                // vendors its own ONNX Runtime 1.27 xcframework (sherpa-onnx needs
                // that version); pulling this one in unconditionally made Xcode
                // fail with "Multiple commands produce onnxruntime.framework" and
                // broke every iOS build in the sibling repo. The ONNX LuxTTS path
                // exists here to A/B against MLX on a desktop — iOS already has
                // its own ONNX engines and needs nothing from this.
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager",
                         condition: .when(platforms: [.macOS])),
                // ORT C API struct layouts for LuxOnnxEngine (header-only).
                "COnnxRuntime",
                // sherpa-onnx C struct layouts for the Pocket TTS backend
                // (PocketSpeechModel dlopens the actual library at runtime).
                "CSherpaOnnx",
            ],
            path: "Sources/EngineKit",
            // convert_weights.py is a one-time dev tool (LuxTTS torch -> safetensors),
            // not compiled or shipped.
            exclude: ["LuxTTS/convert_weights.py"],
            resources: [
                // LuxTTS phoneme vocab (360 entries) consumed by LuxTokenizer.
                .copy("LuxTTS/Resources/tokens.txt")
            ]
        ),
        .testTarget(
            name: "EngineKitTests",
            dependencies: ["EngineKit"],
            path: "Tests/EngineKitTests"
        ),
        .executableTarget(
            name: "spike",
            dependencies: ["EngineKit", "StudioKit"],
            path: "Sources/spike"
        ),
        .target(
            name: "StudioKit",
            dependencies: [
                "EngineKit",
                // Dia2 needs word timings for a conditioning clip, and the
                // transcriber that produces them lives in SpeechKit.
                "SpeechKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/StudioKit"
        ),
        .testTarget(
            name: "StudioKitTests",
            dependencies: [
                "StudioKit",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/StudioKitTests"
        ),
        // One-off maintenance tool: brings references that are ALREADY on disk up
        // to the loudness standard. VoiceLibrary applies the standard at its
        // write sites, so new voices meet it automatically — existing library
        // voices and the bundled .gvoice packs need this run over them once.
        .executableTarget(
            name: "voice-level",
            dependencies: [
                "StudioKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/voice-level"
        ),
        .target(
            name: "SpeechKit",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/SpeechKit"
        ),
        .testTarget(
            name: "SpeechKitTests",
            dependencies: ["SpeechKit"],
            path: "Tests/SpeechKitTests"
        ),
    ]
)
