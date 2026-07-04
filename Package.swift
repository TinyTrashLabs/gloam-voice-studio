// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gloam-voice-studio",
    platforms: [.macOS(.v14)],
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
        .package(
            url: "https://github.com/TinyTrashLabs/mlx-audio-swift.git",
            revision: "f57346ace4ad8fd22e6d56f6e952c9afecce2df7"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.3")),
        // HuggingFace Hub client + Tokenizers — back the mlx-swift-lm #huggingFace…
        // macros (mlx-swift-lm 3.x ships the integration as macros the consumer
        // wires to concrete impls, not a bundled dependency). Both are already in
        // the resolved graph transitively (via mlx-audio-swift / WhisperKit).
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMinor(from: "0.9.0")),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.3.3")),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.19")),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", .upToNextMajor(from: "2.5.0")),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "EngineKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                // MoE Gemma-4 (gemma-4-26b-a4b) is a `Gemma4ForConditionalGeneration`
                // whose expert/router text stack is implemented only in the VLM
                // factory — the LLM factory's dense Gemma4 dies on its MoE weights.
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            path: "Sources/EngineKit"
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
