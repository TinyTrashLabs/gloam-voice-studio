// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gloam-voice-studio",
    platforms: [.macOS(.v14)],
    dependencies: [
        // v0.1.2 (latest tag) predates the Chatterbox port — track main for the
        // spike; pinned to a recorded SHA when the real app build starts.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.3")),
    ],
    targets: [
        .executableTarget(
            name: "spike",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            path: "Sources/spike"
        ),
    ]
)
