/// Time-domain speed change via linear-interpolation resampling.
/// Same approach (and same pitch-shift trade-off at extreme values) as the
/// upstream Python and Swift Fish implementations.
enum SpeedAdjust {
    static func apply(_ samples: [Float], speed: Float) -> [Float] {
        guard abs(speed - 1.0) > 1e-6, !samples.isEmpty else { return samples }
        let newCount = max(1, Int(Float(samples.count) / speed))
        var out = [Float](repeating: 0, count: newCount)
        let step = Float(samples.count) / Float(newCount)
        for i in 0..<newCount {
            let pos = Float(i) * step
            let idx = Int(pos)
            let frac = pos - Float(idx)
            let next = min(idx + 1, samples.count - 1)
            out[i] = samples[idx] * (1 - frac) + samples[next] * frac
        }
        return out
    }

    /// Linear resample between rates — used only on a reference clip for the
    /// speaker encoder, never on a take.
    static func resample(_ samples: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, from > 0, to > 0 else { return samples }
        return apply(samples, speed: Float(from) / Float(to))
    }
}
