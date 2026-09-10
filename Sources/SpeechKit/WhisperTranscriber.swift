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

    /// Actor-reentrant: two first-callers may race to a double init; the
    /// second assignment wins and both get a valid kit — accepted for v1.
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
        // WhisperKit 1.0.0: transcribeWithResults returns [Result<[TranscriptionResult], Error>],
        // one element per input path — failures propagate as thrown SpeechError.
        let results = await kit.transcribeWithResults(
            audioPaths: [audioURL.path],
            decodeOptions: options
        )
        guard let first = results.first else {
            throw SpeechError.transcriptionFailed("Whisper returned no result")
        }
        let segments: [TranscriptionResult]
        do { segments = try first.get() }
        catch { throw SpeechError.transcriptionFailed(error.localizedDescription) }
        let text = segments.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: languageHint)
    }

    /// Word-level timings, which Dia2 needs and nothing else here provided.
    ///
    /// Without this the protocol's default implementation threw
    /// `wordTimingsUnavailable` for EVERY transcriber, so Dia2 prefix
    /// alignment could never be built: only voices that already had a cached
    /// `engines/dia2/alignment.json` could condition a speaker, and picking
    /// any other voice failed. Four of 113 voices on the author's machine had
    /// that cache, so 109 of them silently could not be used with Dia2.
    ///
    /// `wordTimestamps: true` costs an extra alignment pass inside WhisperKit,
    /// which is why it is not on for ordinary dictation.
    public func transcribeWords(audioURL: URL,
                                languageHint: String? = nil) async throws -> [WordTiming] {
        let kit = try await loadedKit()
        let options = DecodingOptions(language: languageHint, wordTimestamps: true)
        let results = await kit.transcribeWithResults(
            audioPaths: [audioURL.path], decodeOptions: options)
        guard let first = results.first else {
            throw SpeechError.transcriptionFailed("Whisper returned no result")
        }
        let transcriptions: [TranscriptionResult]
        do { transcriptions = try first.get() }
        catch { throw SpeechError.transcriptionFailed(error.localizedDescription) }

        let words = transcriptions
            .flatMap(\.segments)
            .flatMap { $0.words ?? [] }
            .map {
                WordTiming(text: $0.word.trimmingCharacters(in: .whitespaces),
                           start: Double($0.start), end: Double($0.end))
            }
            .filter { !$0.text.isEmpty }
        // An empty result is a failure, not an empty transcript: a prefix with
        // no words conditions nothing, and a caller that gets [] back would
        // generate an unconditioned take under the chosen voice's name.
        guard !words.isEmpty else {
            throw SpeechError.transcriptionFailed(
                "Whisper returned no word timings for \(audioURL.lastPathComponent)")
        }
        return words
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
