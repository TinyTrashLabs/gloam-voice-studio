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

    /// Scale so the peak hits `target` of full scale (default −0.18 dBFS ≈ 0.98).
    /// Silence (or already-at-target audio) passes through unchanged.
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
