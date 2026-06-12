import Foundation
import WhisperKit

/// Opt-in local Whisper engine. Loads lazily from a downloaded model folder.
/// Live mode is transcribe-on-stop: chunks are buffered and transcribed once
/// the audio stream finishes (one .final, no partials) — WhisperKit streaming
/// would need its own mic pipeline and isn't worth it for dictation.
public actor WhisperTranscriber: Transcriber {
    private let modelFolder: URL
    private var whisper: WhisperKit?

    public init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    private func loadedKit() async throws -> WhisperKit {
        if let whisper { return whisper }
        do {
            // download: false — model is already local; load: true forces loadModels().
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            whisper = kit
            return kit
        } catch {
            throw SpeechError.engineUnavailable(
                "Whisper model failed to load: \(error.localizedDescription)")
        }
    }

    public func transcribe(audioURL: URL, languageHint: String?) async throws -> Transcript {
        let kit = try await loadedKit()
        let options = DecodingOptions(language: languageHint)
        // WhisperKit 1.0.0: transcribe(audioPaths: [String]) is non-throwing; returns [[TranscriptionResult]?]
        let allResults = await kit.transcribe(
            audioPaths: [audioURL.path],
            decodeOptions: options
        )
        // allResults has one element per input path; flatten the inner array.
        let text = (allResults.first??.map(\.text) ?? [])
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: languageHint)
    }

    public nonisolated func liveTranscribe(audio: AsyncStream<AudioChunk>)
        -> AsyncThrowingStream<TranscriptUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var samples: [Float] = []
                var rate: Double = 16000
                for await chunk in audio {
                    samples.append(contentsOf: chunk.samples)
                    rate = chunk.sampleRate
                }
                guard !samples.isEmpty else { continuation.finish(); return }
                do {
                    // WhisperKit reads files; hand it a temp WAV.
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("whisper-live-\(UUID().uuidString).wav")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try WAVFile.write(samples: samples, sampleRate: Int(rate), to: url)
                    let transcript = try await self.transcribe(audioURL: url,
                                                               languageHint: nil)
                    continuation.yield(.final(transcript.text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Minimal 16-bit PCM WAV writer (StudioKit has one, but SpeechKit must not
/// depend on StudioKit — keep the module standalone for reuse by Converse).
enum WAVFile {
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        let byteRate = UInt32(sampleRate * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))            // PCM
        data.append(littleEndian: UInt16(1))            // mono
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: UInt16(2))            // block align
        data.append(littleEndian: UInt16(16))           // bits
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(pcm.count))
        data.append(pcm)
        try data.write(to: url)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
