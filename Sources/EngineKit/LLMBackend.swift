import Foundation

/// LLM "family" — drives the thinking-off recipe in MLXLanguageModelProvider.
public enum LLMFamily: Sendable, Equatable {
    case qwen
    case gemma
}

/// On-device text-LLM catalog. The Phase 2 bake-off scores these; the winners
/// later map onto the user-facing "Intelligence" notches. Repo ids are
/// MLX-community conversions already supported by mlx-swift-lm v3.31.3.
public enum LLMBackendID: String, CaseIterable, Sendable, Codable {
    case qwen3_1_7b   = "qwen3-1.7b-text"
    case qwen3_8b     = "qwen3-8b-text"
    case gemma4_e2b   = "gemma4-e2b"
    case gemma4_e4b   = "gemma4-e4b"

    public var repoId: String {
        switch self {
        case .qwen3_1_7b: "mlx-community/Qwen3-1.7B-4bit"
        case .qwen3_8b:   "mlx-community/Qwen3-8B-4bit"
        case .gemma4_e2b: "mlx-community/gemma-4-e2b-it-4bit"
        case .gemma4_e4b: "mlx-community/gemma-4-e4b-it-4bit"
        }
    }

    public var family: LLMFamily {
        switch self {
        case .qwen3_1_7b, .qwen3_8b: .qwen
        case .gemma4_e2b, .gemma4_e4b: .gemma
        }
    }

    /// Approximate on-disk download size (bytes), for the disk preflight check.
    public var approxBytes: Int64 {
        switch self {
        case .qwen3_1_7b: 1_100_000_000
        case .qwen3_8b:   4_700_000_000
        case .gemma4_e2b: 1_600_000_000
        case .gemma4_e4b: 3_000_000_000
        }
    }

    /// On-disk folder name under the managed Models directory.
    public var diskFolder: String { "llm-\(rawValue)" }
}
