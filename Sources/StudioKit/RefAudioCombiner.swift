import AVFAudio
import Foundation

/// Combines several reference clips into one cloning reference: each clip is
/// decoded, resampled to a common rate, mono-mixed, peak-normalized (so a
/// quiet phone clip doesn't vanish next to a studio one), and concatenated
/// with a short silence gap; transcripts join in order. More reference
/// material generally means a steadier clone. (Idea borrowed from Voicebox's
/// combine_voice_prompts, MIT.)
public enum RefAudioCombiner {
    public static let targetSampleRate = 44_100.0
    static let gapSeconds = 0.25

    /// Combine decoded clips + transcripts into (wav, joined transcript).
    /// Throws if any clip fails to decode; validate clips individually first
    /// for better error surfacing.
    public static func combine(clips: [(wav: Data, transcript: String)]) throws
        -> (wav: Data, transcript: String)
    {
        precondition(!clips.isEmpty, "combine requires at least one clip")
        var combined: [Float] = []
        let gap = [Float](repeating: 0, count: Int(targetSampleRate * gapSeconds))
        for (index, clip) in clips.enumerated() {
            if index > 0 { combined.append(contentsOf: gap) }
            let samples = try decodeMono(clip.wav)
            combined.append(contentsOf: AudioAssembler.normalizePeak(floats: samples))
        }
        let transcript = clips.map {
            $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: " ")
        return (WAVEncoder.encode(pcm16: PCM16.data(from: combined),
                                  sampleRate: Int(targetSampleRate)),
                transcript)
    }

    /// Decode arbitrary audio data to mono floats at the target rate.
    static func decodeMono(_ data: Data) throws -> [Float] {
        // AVAudioFile needs a URL; stage the bytes in a temp file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("refcombine-\(UUID().uuidString).audio")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetSampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outFormat)
        else { throw StudioError.invalidRefAudio("unsupported audio format") }

        var out: [Float] = []
        var reachedEnd = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)
            else { throw StudioError.invalidRefAudio("buffer allocation failed") }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { count, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: count) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let conversionError {
                throw StudioError.invalidRefAudio(conversionError.localizedDescription)
            }
            if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                           count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || outBuffer.frameLength == 0 { break }
        }
        guard !out.isEmpty else { throw StudioError.invalidRefAudio("clip decoded to silence") }
        return out
    }
}
