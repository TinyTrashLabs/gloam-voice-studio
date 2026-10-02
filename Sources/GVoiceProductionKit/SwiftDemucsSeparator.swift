import Foundation
import SwiftDemucs

public protocol VoiceStemSeparating: Sendable {
    var backendIdentifier: String { get }
    var modelIdentifier: String { get }
    func isolateVocals(_ input: ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer
}

public final class SwiftDemucsSeparator: VoiceStemSeparating, @unchecked Sendable {
    public let backendIdentifier = "swift-demucs-mlx"
    public let modelIdentifier = "htdemucs_ft"
    private let operation: (ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer

    public init(weightsDirectory: URL) async throws {
        let weights = weightsDirectory.appendingPathComponent("htdemucs_ft_vocals.safetensors")
        guard FileManager.default.isReadableFile(atPath: weights.path) else {
            throw ReferencePreparationError.separationUnavailable("missing \(weights.lastPathComponent)")
        }
        let separator: VocalSeparator
        do { separator = try await VocalSeparator(weightsDirectory: weightsDirectory) }
        catch { throw ReferencePreparationError.separationUnavailable(String(describing: error)) }
        operation = { input in
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("gvoice-demucs-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let prepared = try NativeAudioProcessor.resample(input, to: 44_100)
            let source = work.appendingPathComponent("source.wav")
            try NativeAudioProcessor.pcm16WAV(prepared).write(to: source, options: .atomic)
            let result = try await withTaskCancellationHandler {
                try await separator.separateVocals(from: source, to: work)
            } onCancel: {
                separator.cancel()
            }
            return try NativeAudioProcessor.decode(result.vocalsURL)
        }
    }

    init(testing operation: @escaping (ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer) {
        self.operation = operation
    }

    static func testing(_ operation: @escaping (ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer) -> SwiftDemucsSeparator {
        SwiftDemucsSeparator(testing: operation)
    }

    public func isolateVocals(_ input: ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer {
        guard input.channelCount == 2 else { throw ReferencePreparationError.stereoSourceRequired }
        try Task.checkCancellation()
        return try await operation(input)
    }
}
