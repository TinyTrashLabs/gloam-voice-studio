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

/// Streaming counterpart of `PitchPreservingSpeed`: ONE stretcher for a whole
/// stream, so chunk seams are continuous (no per-chunk reset, no gaps). Pace is
/// fixed for the stream. The stretcher's latency is skipped once at the start
/// (its first `skip` output samples are discarded) and made up once in
/// `finish()` by flushing, so the total is `input / speed` like the one-shot.
final class PitchPreservingStream {
    private let ref: GVFXStretchRef?
    private let speed: Float
    private let skipTotal: Int
    private var skipLeft: Int
    private var inTotal = 0
    private var produced = 0      // output samples the stretcher has made (incl. skipped)
    private var carry: Double = 0 // fractional output samples owed across chunks
    private var finished = false

    init(speed: Float, sampleRate: Int) {
        self.speed = speed
        ref = gvfx_stretch_create(1, Float(sampleRate))
        let inLat = Double(gvfx_stretch_input_latency(ref)), outLat = Double(gvfx_stretch_output_latency(ref))
        skipTotal = Int((inLat / Double(speed) + outLat).rounded())
        skipLeft = skipTotal
    }

    deinit { gvfx_stretch_destroy(ref) }

    /// Audio ready to play for `chunk` (may be empty while the latency is skipped).
    func push(_ chunk: [Float]) -> [Float] {
        guard !chunk.isEmpty, !finished else { return [] }
        guard ref != nil else { return SpeedAdjust.apply(chunk, speed: speed) }
        inTotal += chunk.count
        let exact = Double(chunk.count) / Double(speed) + carry
        let n = Int(exact.rounded(.down))
        carry = exact - Double(n)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        chunk.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                gvfx_stretch_process(ref, inp.baseAddress, Int32(chunk.count), o.baseAddress, Int32(n))
            }
        }
        produced += n
        return dropSkipped(out)
    }

    /// The tail the stretcher still holds. Call once, after the last `push`.
    func finish() -> [Float] {
        guard !finished, ref != nil else { return [] }
        finished = true
        let want = Int((Double(inTotal) / Double(speed)).rounded()) + skipTotal - produced
        guard want > 0 else { return [] }
        var out = [Float](repeating: 0, count: want)
        out.withUnsafeMutableBufferPointer {
            gvfx_stretch_flush(ref, $0.baseAddress, Int32(want), speed)
        }
        return dropSkipped(out)
    }

    private func dropSkipped(_ out: [Float]) -> [Float] {
        guard skipLeft > 0 else { return out }
        let d = min(skipLeft, out.count)
        skipLeft -= d
        return Array(out.dropFirst(d))
    }
}
