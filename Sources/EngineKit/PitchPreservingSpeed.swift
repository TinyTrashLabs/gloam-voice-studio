import CSignalsmithStretch

/// Pace change that keeps pitch: a phase-vocoder time stretch (Signalsmith
/// Stretch) rather than `SpeedAdjust`'s linear resample, which shifts pitch by
/// the same ratio. Used for Audio8 only.
enum PitchPreservingSpeed {
    /// `speed` > 1 is faster (shorter). Output length is `count / speed`.
    /// Latency is compensated inside the library, so the output is aligned
    /// with the input onset.
    static func apply(_ samples: [Float], speed: Float, sampleRate: Int) -> [Float] {
        guard abs(speed - 1.0) > 1e-6, !samples.isEmpty, speed > 0, sampleRate > 0 else {
            return samples
        }
        let outCount = max(1, Int((Float(samples.count) / speed).rounded()))
        guard let ref = gvfx_stretch_create(1, Float(sampleRate)) else {
            return SpeedAdjust.apply(samples, speed: speed)
        }
        defer { gvfx_stretch_destroy(ref) }
        var out = [Float](repeating: 0, count: outCount)
        let ok = samples.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                gvfx_stretch_exact(ref, inp.baseAddress, Int32(samples.count),
                                   o.baseAddress, Int32(outCount))
            }
        }
        // Too short for the stretcher's window: fall back rather than return silence.
        return ok == 1 ? out : SpeedAdjust.apply(samples, speed: speed)
    }
}
