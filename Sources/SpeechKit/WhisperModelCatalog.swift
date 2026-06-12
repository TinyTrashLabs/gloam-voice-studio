import Foundation

/// The Whisper models we surface in Settings. Variants are subfolder names
/// in the argmaxinc/whisperkit-coreml HuggingFace repo.
public struct WhisperModelCatalog: Sendable {
    public struct Model: Identifiable, Equatable, Sendable {
        public var id: String { variant }
        public let variant: String
        public let displayName: String
        public let approxBytes: Int64
    }

    public static let repo = "argmaxinc/whisperkit-coreml"
    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"

    public static let models: [Model] = [
        Model(variant: "openai_whisper-small",
              displayName: "Whisper Small — fast, good accuracy",
              approxBytes: 500_000_000),
        Model(variant: "openai_whisper-large-v3-v20240930_turbo",
              displayName: "Whisper Large v3 Turbo — best accuracy",
              approxBytes: 650_000_000),
    ]
}
