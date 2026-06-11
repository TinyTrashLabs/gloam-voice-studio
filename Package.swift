// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gloam-voice-studio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EngineKit", targets: ["EngineKit"]),
    ],
    dependencies: [
        // Pinned to the revision validated by the Phase 0 spike (SPIKE-RESULTS.md).
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "10b7366204fd3991458de690f3d49651251055f5"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.3")),
    ],
    targets: [
        .target(
            name: "EngineKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
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
