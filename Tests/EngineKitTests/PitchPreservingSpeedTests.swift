import XCTest
import Accelerate
@testable import EngineKit

final class PitchPreservingSpeedTests: XCTestCase {
    private let rate = 44100

    private func sine(_ hz: Float, seconds: Float, offsetSeconds: Float = 0) -> [Float] {
        let n = Int(seconds * Float(rate)), off = Int(offsetSeconds * Float(rate))
        return (0..<n).map { $0 < off ? 0 : 0.5 * sin(2 * .pi * hz * Float($0) / Float(rate)) }
    }

    func testSpeedOneIsIdentity() {
        let x = sine(220, seconds: 0.5)
        XCTAssertEqual(PitchPreservingSpeed.apply(x, speed: 1.0, sampleRate: rate), x)
    }

    func testLengthScalesWithSpeed() {
        let x = sine(220, seconds: 2)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        let want = Double(x.count) / 1.2
        XCTAssertEqual(Double(y.count), want, accuracy: want * 0.01)
    }

    /// Dominant frequency by zero-crossing rate over the steady middle.
    private func dominantHz(_ y: [Float]) -> Float {
        let a = y.count / 4, b = 3 * y.count / 4
        var crossings = 0
        for i in (a + 1)..<b where (y[i - 1] < 0) != (y[i] < 0) { crossings += 1 }
        return Float(crossings) / 2 / (Float(b - a) / Float(rate))
    }

    func testPitchIsPreserved() {
        let x = sine(220, seconds: 2)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        XCTAssertEqual(dominantHz(y), 220, accuracy: 220 * 0.02)
        // The resample it replaces would land at 264 Hz.
        XCTAssertEqual(dominantHz(SpeedAdjust.apply(x, speed: 1.2)), 264, accuracy: 264 * 0.02)
    }

    func testNoLatencyGap() {
        // 100 ms of silence, then a tone: output onset (scaled) must match.
        let x = sine(220, seconds: 2, offsetSeconds: 0.1)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        let first = y.firstIndex { abs($0) > 0.25 } ?? y.count  // half amplitude: ignores window pre-echo
        let expected = Int(0.1 * Float(rate) / 1.2)
        XCTAssertEqual(Double(first), Double(expected), accuracy: 0.005 * Double(rate))
    }

    func testTooShortInputFallsBackNotSilent() {
        let x = sine(220, seconds: 0.01)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        XCTAssertFalse(y.isEmpty)
        XCTAssertTrue(y.contains { abs($0) > 0.1 })
    }

    func testLengthAtSlowSpeed() {
        let x = sine(220, seconds: 2)
        let y = PitchPreservingSpeed.apply(x, speed: 0.9, sampleRate: rate)
        let want = Double(x.count) / 0.9
        XCTAssertEqual(Double(y.count), want, accuracy: want * 0.01)
        XCTAssertEqual(dominantHz(y), 220, accuracy: 220 * 0.02)
    }

    // MARK: stream stretcher

    /// Uneven chunks, like a model's streamed decode.
    private func streamed(_ x: [Float], speed: Float, sizes: [Int] = [3000, 7777, 12345, 999, 20000]) -> [Float] {
        let s = PitchPreservingStream(speed: speed, sampleRate: rate)
        var out: [Float] = [], i = 0, k = 0
        while i < x.count {
            let n = min(sizes[k % sizes.count], x.count - i); k += 1
            out += s.push(Array(x[i..<(i + n)])); i += n
        }
        return out + s.finish()
    }

    func testStreamLengthAndPitch() {
        let x = sine(220, seconds: 4)
        for speed: Float in [1.2, 0.9] {
            let y = streamed(x, speed: speed)
            let want = Double(x.count) / Double(speed)
            XCTAssertEqual(Double(y.count), want, accuracy: want * 0.01, "speed \(speed)")
            XCTAssertEqual(dominantHz(y), 220, accuracy: 220 * 0.02, "speed \(speed)")
        }
    }

    /// Speech-like signal: a 220 Hz tone with a slow syllable-rate envelope.
    private func syllables(seconds: Float) -> [Float] {
        let n = Int(seconds * Float(rate))
        return (0..<n).map { i in
            let t = Float(i) / Float(rate)
            let env = max(0, sin(2 * .pi * 3 * t))
            return 0.5 * env * sin(2 * .pi * 220 * t)
        }
    }

    /// RMS envelope in 10 ms windows.
    private func envelope(_ y: [Float]) -> [Float] {
        let w = rate / 100
        return stride(from: 0, to: y.count - w, by: w).map { a in
            sqrt(y[a..<(a + w)].reduce(0) { $0 + $1 * $1 } / Float(w))
        }
    }

    /// Chunked and whole-buffer output cannot match sample for sample (the phase
    /// vocoder's phases depend on its history), so compare what a listener hears
    /// over time: the loudness envelope, by Pearson correlation. Misalignment or
    /// gaps at seams would drop it well under 0.95.
    func testStreamMatchesWholeBufferEnvelope() {
        let x = syllables(seconds: 4)
        let whole = envelope(PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate))
        let chunked = envelope(streamed(x, speed: 1.2))
        let n = min(whole.count, chunked.count)
        XCTAssertLessThanOrEqual(abs(whole.count - chunked.count), 2)
        let a = Array(whole[..<n]), b = Array(chunked[..<n])
        let ma = a.reduce(0, +) / Float(n), mb = b.reduce(0, +) / Float(n)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<n { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
        XCTAssertGreaterThanOrEqual(num / sqrt(da * db), 0.95)
    }

    func testStreamHasNoSeamGaps() {
        let x = sine(220, seconds: 3)
        let y = streamed(x, speed: 1.2)
        // Steady tone: no 10 ms window in the body may drop out.
        let env = envelope(y)
        for e in env.dropFirst(5).dropLast(5) { XCTAssertGreaterThan(e, 0.2) }
    }

    func testAudio8PlanCarriesNoNativeSpeed() throws {
        let plan = try RequestPlanner.plan(
            backend: .audio8,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", refText: "hello", speed: 1.2))
        XCTAssertNil(plan.speed, "audio8 pace is post-hoc; a native speed would skip the stretch")
    }
}

/// Model-backed (skipped unless AUDIO8_MODEL_DIR / AUDIO8_REF_WAV / AUDIO8_REF_TEXT are set).
final class Audio8PaceStreamModelTests: XCTestCase {
    func testStreamedPaceYieldsEarlyChunks() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["AUDIO8_MODEL_DIR"], !dir.isEmpty else {
            throw XCTSkip("set AUDIO8_MODEL_DIR to run Audio8 model-backed tests")
        }
        let wav = env["AUDIO8_REF_WAV"] ?? "", text = env["AUDIO8_REF_TEXT"] ?? ""
        try XCTSkipUnless(!wav.isEmpty && !text.isEmpty && FileManager.default.fileExists(atPath: wav),
                          "set AUDIO8_REF_WAV and AUDIO8_REF_TEXT")
        let engine = GloamEngine(provider: MLXModelProvider(modelPathResolver: { $0 == .audio8 ? dir : nil }))
        let request = SynthesisRequest(
            text: "Alright night owls, that was a slow one to ease you in. Grab something warm, settle into the corner booth, and stay a while. We have got plenty more coming up after this.",
            refAudioPath: wav, refText: text, speed: 1.2)
        let start = Date()
        var arrivals: [(Double, Int)] = []
        for try await chunk in await engine.synthesizeStream(backend: .audio8, request: request) {
            arrivals.append((Date().timeIntervalSince(start), chunk.samples.count))
        }
        let wall = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(arrivals.count, 2, "streams in pieces at speed 1.2")
        XCTAssertLessThan(try XCTUnwrap(arrivals.first).0, wall * 0.5, "first chunk before half the wall time")
    }
}
