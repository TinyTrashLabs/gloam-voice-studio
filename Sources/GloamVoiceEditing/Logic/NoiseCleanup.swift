import Foundation

/// Removes background noise from a 24 kHz reference take. The model is the
/// host's (the iPhone ships DPDFNet); the rules for when to offer it and how
/// its output is mixed back are here, so every app cleans a take the same way.
public protocol SpeechDenoiser: Sendable {
    var name: String { get }
    func denoise(_ samples24k: [Float]) async throws -> [Float]
}

public enum NoiseCleanup {
    /// Offer cleanup only when there is noise to remove: on clean speech a
    /// denoiser can only subtract voice, and the clone learns its artefacts.
    public static let offerBelowSNRDb: Float = 35
    /// Mix the noisy input back in this far down, so over-suppression never
    /// leaves the "watery" voice a full-strength denoiser makes of quiet
    /// consonants. DeepFilterNet's own default attenuation limit is in this range.
    public static let attenuationLimitDb: Float = 18

    public static func worthOffering(_ q: RecordingCheck.Quality) -> Bool { q.snrDb < offerBelowSNRDb }

    public static func mix(dry: [Float], wet: [Float], attenuationLimitDb: Float) -> [Float] {
        let g = pow(10, -attenuationLimitDb / 20)
        let n = min(dry.count, wet.count)
        return (0..<n).map { wet[$0] + g * dry[$0] }
    }

    /// Delay of `b` relative to `a`, in samples, by cross-correlation over a
    /// window -- the mix is only valid if the denoiser's lookahead was compensated.
    public static func lag(_ a: [Float], _ b: [Float], maxLag: Int) -> Int {
        let n = min(a.count, b.count, 48000)
        var best = 0, bestScore = -Float.infinity
        for l in 0...maxLag {
            var s: Float = 0
            for i in 0..<(n - l) { s += a[i] * b[i + l] }
            if s > bestScore { bestScore = s; best = l }
        }
        return best
    }

    /// Denoise, align, and mix. Returns 24 kHz, same length as the input.
    public static func clean(_ samples24k: [Float], with d: SpeechDenoiser) async throws -> [Float] {
        var wet = try await d.denoise(samples24k)
        let l = lag(samples24k, wet, maxLag: 2400)   // 100 ms
        if l > 0 { wet = Array(wet.dropFirst(l)) + [Float](repeating: 0, count: l) }
        if wet.count < samples24k.count { wet += [Float](repeating: 0, count: samples24k.count - wet.count) }
        return mix(dry: samples24k, wet: Array(wet.prefix(samples24k.count)), attenuationLimitDb: attenuationLimitDb)
    }
}

extension VoiceQualifier {
    /// The candidates "Check this voice" weighs, for a host whose
    /// `VoiceCheckCapability.candidates` has a denoiser to offer.
    ///
    /// Always the original (`original`, the prepared take the clone would
    /// use today). Plus `cleaned` when the take's noise makes it worth
    /// offering and a denoiser is given: the denoiser runs on the RAW take
    /// (`raw`), then the usual trim-and-level, then a temp WAV. A cleanup
    /// that fails is logged and left out -- the original still clones.
    public static func candidates(original: URL, raw: URL, transcript: String, quality: RecordingCheck.Quality,
                                  denoiser: SpeechDenoiser?) async -> [ReferenceCandidate] {
        let originalSamples = (try? VoiceAudio.loadWav24k(original)) ?? []
        var out = [ReferenceCandidate(kind: .original, url: original, samples24k: originalSamples, transcript: transcript)]
        guard NoiseCleanup.worthOffering(quality), let denoiser else { return out }
        do {
            let rawSamples = try VoiceAudio.loadWav24k(raw)
            let started = Date()
            let denoised = try await NoiseCleanup.clean(rawSamples, with: denoiser)
            let cleaned = RecordingCleanup.clean(denoised, sampleRate: ClipImport.sampleRate)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleaned-\(UUID().uuidString).wav")
            try VoicePlayer.wavData(samples: cleaned, sampleRate: ClipImport.sampleRate).write(to: url)
            NSLog("[qualify] cleaned candidate (%@, SNR %.0f dB) in %.1f s", denoiser.name, quality.snrDb,
                  Date().timeIntervalSince(started))
            out.append(ReferenceCandidate(kind: .cleaned, url: url, samples24k: cleaned, transcript: transcript))
        } catch {
            NSLog("[qualify] cleanup failed (%@); original only", error.localizedDescription)
        }
        return out
    }
}
