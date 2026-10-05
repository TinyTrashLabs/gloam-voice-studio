import AVFoundation
import Foundation

/// Plays a `[Float]` buffer or an audio file via AVAudioPlayer (float → PCM16
/// WAV in Documents, so the last render is also inspectable/shareable),
/// publishing `isPlaying`. The editor's player; the Studio app subclasses it
/// (`SignalPlayer`) to add streamed, chunked playback, so there is ONE copy of
/// the play/stop/encode path.
open class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public var isPlaying = false

    /// The player of the current clip. `open` access so a subclass that adds
    /// its own playback modes can read progress from it.
    public var player: AVAudioPlayer?

    public override init() { super.init() }

    public static var lastRenderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last-render.wav")
    }

    /// Default playback level for rendered voice, 0.8× unity: the value the
    /// radio app settled on ("the DJ was too loud at 1.0, esp. on iOS"). An
    /// app constant, not a pack field — the pack's per-voice `gain` (dB) is
    /// applied on top by `outputGain(voiceGainDb:)`.
    public static let outputLevel: Float = 0.8

    /// `outputLevel` × the voice's own trim. `gain` is dB, clamped to ±12 as
    /// the format requires; non-finite is treated as absent.
    public static func outputGain(voiceGainDb: Double?) -> Float {
        guard let db = voiceGainDb, db.isFinite else { return outputLevel }
        let clamped = max(-12, min(12, db))
        return outputLevel * Float(pow(10, clamped / 20))
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    open func play(samples: [Float], sampleRate: Int, gain: Float = 1) throws {
        let samples = gain == 1 ? samples : samples.map { max(-1, min(1, $0 * gain)) }
        activateSession()

        let url = Self.lastRenderURL
        try Self.wavData(samples: samples, sampleRate: sampleRate).write(to: url)

        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        player = p
        p.play()
        isPlaying = true
    }

    /// Play an already-encoded audio file (render-history replay, or a
    /// voice's reference clip). Decodes to mono `Float` samples and routes
    /// through `play(samples:sampleRate:gain:)` rather than setting
    /// `AVAudioPlayer.volume` — that path scales+clips in sample space, this
    /// one used to apply gain as playback volume, and the two are not the
    /// same curve. One gain path means a reference clip previewed here
    /// matches what the voice actually renders at, not a volume knob's idea
    /// of the same number.
    public func play(fileURL url: URL, gain: Float = 1) throws {
        let (samples, sampleRate) = try Self.monoSamples(from: url)
        // An empty or unreadable file must surface as an error, not a silent
        // "playing" state that never ends.
        guard !samples.isEmpty else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        try play(samples: samples, sampleRate: sampleRate, gain: gain)
    }

    /// Decodes an audio file to mono `Float` samples at its own sample rate,
    /// downmixing multichannel audio by averaging channels.
    private static func monoSamples(from url: URL) throws -> ([Float], Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              file.length > 0
        else { return ([], Int(format.sampleRate)) }
        try file.read(into: buffer)
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard let channelData = buffer.floatChannelData, frameCount > 0, channelCount > 0 else {
            return ([], Int(format.sampleRate))
        }
        var samples = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channelCount {
            let chPtr = channelData[ch]
            for i in 0..<frameCount { samples[i] += chPtr[i] }
        }
        if channelCount > 1 {
            let inv = 1 / Float(channelCount)
            for i in 0..<frameCount { samples[i] *= inv }
        }
        return (samples, Int(format.sampleRate))
    }

    open func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    open func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false }
    }

    /// Minimal mono PCM16 WAV encoder.
    /// Pure, so callable off the main actor (the clone-time cleanup writes
    /// its candidate from a background task).
    public nonisolated static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var v = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        let byteRate = UInt32(sampleRate * 2)
        var data = Data()
        func append(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16); append16(1); append16(1) // PCM, mono
        append(UInt32(sampleRate)); append(byteRate)
        append16(2); append16(16) // block align, bits
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
