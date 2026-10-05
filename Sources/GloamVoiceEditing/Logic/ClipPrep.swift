import Foundation

/// Two small clean-ups an audio clip gets before it is a reference: the
/// room tone trimmed off both ends, and any DC bias removed. Lifted out of the
/// Studio app's `LuxMel` (which keeps forwarding to it) so the clip importer
/// and the engine's mel front end share ONE copy.
public enum ClipPrep {
    /// Port of the macOS engine's `LuxMelFeatures.trimAndFade`. Leading and
    /// trailing room tone inflates the frame count without adding any tokens,
    /// which skews the frames-per-token ratio the duration predictor runs on.
    /// A short fade avoids the click a hard cut would leave.
    public static func trimAndFade(_ samples: [Float], sampleRate: Int = 24_000,
                                   thresholdDB: Float = -42, keepSilenceMs: Float = 35,
                                   fadeMs: Float = 12) -> [Float] {
        guard !samples.isEmpty, let peak = samples.map({ abs($0) }).max(), peak > 1e-8 else {
            return samples
        }
        let threshold = peak * pow(10, thresholdDB / 20)
        guard let firstActive = samples.firstIndex(where: { abs($0) > threshold }),
              let lastActive = samples.lastIndex(where: { abs($0) > threshold })
        else { return samples }

        let keep = max(0, Int(Float(sampleRate) * max(keepSilenceMs, 0) / 1000))
        let start = max(0, firstActive - keep)
        let end = min(samples.count, lastActive + keep + 1)
        guard end - start > 8 else { return samples }
        var trimmed = Array(samples[start..<end])

        let fadeSamples = max(0, Int(Float(sampleRate) * max(fadeMs, 0) / 1000))
        if fadeSamples > 1, trimmed.count > fadeSamples * 2 {
            for i in 0..<fadeSamples {
                let ramp = Float(i) / Float(fadeSamples)
                trimmed[i] *= ramp
                trimmed[trimmed.count - 1 - i] *= ramp
            }
        }
        return trimmed
    }

    /// Remove DC bias, matching the macOS engine (and LuxTTS-mlx) before mel.
    public static func removeDC(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        return samples.map { $0 - mean }
    }
}
