import Foundation

/// Post-production helpers for assembled exports: stitch takes with silence
/// gaps and peak-normalize. All operations are on 16-bit LE mono PCM.
public enum AudioAssembler {
    /// Concatenate clips with `gapSeconds` of silence between consecutive clips.
    public static func stitch(_ clips: [Data], sampleRate: Int,
                              gapSeconds: Double) -> Data {
        let gapSamples = max(0, Int(gapSeconds * Double(sampleRate)))
        let gap = Data(repeating: 0, count: gapSamples * 2)
        var out = Data()
        for (index, clip) in clips.enumerated() {
            if index > 0 { out.append(gap) }
            out.append(clip)
        }
        return out
    }

    /// Short linear fade-in/out at the clip edges so back-to-back playback of
    /// separately-synthesized chunks (chat speaks sentence groups) never
    /// clicks at the seams. 8ms is inaudible as a fade but kills the step
    /// discontinuity. (Declick idea borrowed from Voicebox's chunked TTS
    /// crossfade, MIT — we fade edges instead of crossfading because chunks
    /// play as separate queue items, not one concatenated stream.)
    public static func fadeEdges(_ samples: [Float], sampleRate: Int,
                                 milliseconds: Double = 8) -> [Float] {
        let fade = min(max(0, Int(Double(sampleRate) * milliseconds / 1000)),
                       samples.count / 2)
        guard fade > 0 else { return samples }
        var out = samples
        for i in 0 ..< fade {
            let gain = Float(i) / Float(fade)
            out[i] *= gain
            out[out.count - 1 - i] *= gain
        }
        return out
    }

    /// Scale so the peak hits `target` of full scale (default −0.18 dBFS ≈ 0.98).
    /// Silence (or already-at-target audio) passes through unchanged.
    /// Peak-normalize float samples (range [-1, 1]) to `target` full-scale.
    /// Fish output peaks at only ~6–9% while Chatterbox hits ~95%, so without
    /// this Fish takes sound far quieter than Chatterbox on playback/export.
    /// Already-near-target clips are returned untouched.
    public static func normalizePeak(floats samples: [Float],
                                     target: Float = 0.98) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 1e-6 else { return samples }
        let scale = target / peak
        guard abs(scale - 1) > 1e-3 else { return samples }
        return samples.map { max(-1.0, min(1.0, $0 * scale)) }
    }

    public static func normalizePeak(_ pcm: Data, target: Float = 0.98) -> Data {
        var peak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) {
                peak = max(peak, Int32(abs(Int32(Int16(littleEndian: v)))))
            }
        }
        guard peak > 0 else { return pcm }
        let scale = target * 32767.0 / Float(peak)
        guard abs(scale - 1) > 1e-3 else { return pcm }
        var out = Data(capacity: pcm.count)
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) {
                let scaled = Float(Int16(littleEndian: v)) * scale
                let clamped = max(-32767, min(32767, scaled))
                out.append(Int16(clamped).leData)
            }
        }
        return out
    }
}
