import XCTest
@testable import VoiceFXKit

final class FXChainTests: XCTestCase {
    /// Two gain stages in series multiply. Proves composition and buffer
    /// hand-off between stages, which every later stage relies on.
    func testChainAppliesStagesInSeries() {
        let chain = FXChain(stages: [GainStage(gain: 2), GainStage(gain: 3)])
        chain.prepare(sampleRate: 48_000, maxBlock: 512)
        let out = chain.applyWhole([1, 2, 3])
        XCTAssertEqual(out, [6, 12, 18])
    }

    /// The keystone property, proven here on a trivial chain so the harness
    /// exists before any stateful stage does.
    func testWholeBufferEqualsChunked() {
        let input = (0..<1000).map { Float(sin(Double($0) * 0.01)) }
        let whole = FXChain(stages: [GainStage(gain: 0.5)])
        whole.prepare(sampleRate: 48_000, maxBlock: 1000)
        let expected = whole.applyWhole(input)

        let chunked = FXChain(stages: [GainStage(gain: 0.5)])
        chunked.prepare(sampleRate: 48_000, maxBlock: 1000)
        var actual: [Float] = []
        var i = 0
        for size in [1, 7, 64, 3, 200, 500, 229] {
            let n = min(size, input.count - i)
            if n <= 0 { break }
            var outBuf = [Float](repeating: 0, count: n)
            input.withUnsafeBufferPointer { inBuf in
                outBuf.withUnsafeMutableBufferPointer { o in
                    chunked.process(inBuf.baseAddress! + i, o.baseAddress!, frames: n)
                }
            }
            actual += outBuf
            i += n
        }
        XCTAssertEqual(actual.count, i)
        for k in 0..<i {
            XCTAssertEqual(actual[k], expected[k], accuracy: 1e-6)
        }
    }

    func testLatencyIsSumOfStages() {
        let chain = FXChain(stages: [FixedLatencyStage(latencyFrames: 3),
                                     FixedLatencyStage(latencyFrames: 40)])
        chain.prepare(sampleRate: 48_000, maxBlock: 512)
        XCTAssertEqual(chain.latencyFrames, 43)
    }

    func testEmptyChainPassesThrough() {
        let chain = FXChain(stages: [])
        chain.prepare(sampleRate: 48_000, maxBlock: 512)
        XCTAssertEqual(chain.applyWhole([1, 2, 3]), [1, 2, 3])
    }

    /// Pins the maxBlock > 0 guard's positive invariant: after a correct
    /// `prepare`, applyWhole terminates (rather than spinning forever, which
    /// is what happened before the guard when maxBlock was left at 0) and
    /// correctly handles an input length that is not a multiple of maxBlock.
    /// Finding 2: the chain must sanitise non-finite input once, upstream of
    /// every stage — including a stateful one with IIR memory a single NaN
    /// would otherwise poison permanently. Feeds NaN/Inf followed by ordinary
    /// audio through a Butterworth stage and asserts both that all output is
    /// finite AND that the filter still passes signal afterwards; the latter
    /// is what actually catches poisoning, since a finiteness-only check can
    /// pass while the filter's memory is permanently ruined.
    func testChainSanitisesNonFiniteInputBeforeStatefulStage() {
        let sr = 48_000.0
        let n = 4_800
        var input = [Float](repeating: 0, count: n)
        input[0] = .nan
        input[1] = .infinity
        input[2] = -.infinity
        for i in 100..<n {
            let t = Double(i) / sr
            input[i] = Float(sin(2 * Double.pi * 220 * t) * 0.5)
        }

        let chain = FXChain(stages: [ButterworthStage(kind: .highpass, frequency: 300)])
        chain.prepare(sampleRate: sr, maxBlock: n)
        let out = chain.applyWhole(input)

        XCTAssertTrue(out.allSatisfy { $0.isFinite }, "non-finite sample leaked through the chain")

        let tail = Array(out[(3 * n / 4)...])
        let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.01, "filter memory appears permanently poisoned after non-finite input")
    }

    func testApplyWholeTerminatesOnNonMultipleLengths() {
        let chain = FXChain(stages: [GainStage(gain: 2)])
        chain.prepare(sampleRate: 48_000, maxBlock: 300)
        let input = (0..<1000).map { Float($0) }
        let out = chain.applyWhole(input)
        XCTAssertEqual(out.count, 1000)
        for k in 0..<1000 {
            XCTAssertEqual(out[k], input[k] * 2, accuracy: 1e-6)
        }
    }
}

/// Finding 3: `clamped()` must supply a default limiter when a preset omits
/// one, so an inline preset sent over the network can't skip the safety
/// stage. "The limiter is last, always" (FXChain+Preset) must not be
/// optional.
final class FXPresetDefaultLimiterTests: XCTestCase {
    func testClampedSuppliesDefaultLimiterWhenAbsent() throws {
        let json = """
        {
          "version": 1,
          "name": "no-limiter",
          "drive": { "preGain": 8, "postGain": 2, "shape1": 1, "shape2": -1 }
        }
        """
        let decoded = try JSONDecoder().decode(FXPreset.self, from: Data(json.utf8))
        XCTAssertNil(decoded.limiter, "test fixture should start with no limiter section")

        let clamped = decoded.clamped()
        let limiter = try XCTUnwrap(clamped.limiter, "clamped() must supply a default limiter")
        XCTAssertGreaterThan(limiter.ceiling, 0)
        XCTAssertLessThanOrEqual(limiter.ceiling, 1.0)
    }

    func testChainFromLimiterlessPresetStillLimitsHotSignal() throws {
        let json = """
        {
          "version": 1,
          "name": "no-limiter-hot",
          "drive": { "preGain": 20, "postGain": 4, "shape1": 5, "shape2": -5 }
        }
        """
        let decoded = try JSONDecoder().decode(FXPreset.self, from: Data(json.utf8))
        let preset = decoded.clamped()
        let ceiling = try XCTUnwrap(preset.limiter?.ceiling)

        let chain = FXChain.make(from: preset)
        let sr = 48_000.0
        let n = 4_800
        chain.prepare(sampleRate: sr, maxBlock: n)
        // Deliberately hot input, well above the ceiling before drive/limit.
        let input: [Float] = (0..<n).map { i in
            Float(sin(2 * Double.pi * 220 * Double(i) / sr)) * 0.99
        }
        let out = chain.applyWhole(input)
        let peak = out.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, ceiling + 1e-3,
                                 "chain from a limiter-less preset exceeded the (default-supplied) ceiling")
    }
}

/// Declares latency without doing anything to the signal, so latency
/// accounting can be tested independently of any real stage.
private final class FixedLatencyStage: FXStage {
    let latencyFrames: Int
    init(latencyFrames: Int) { self.latencyFrames = latencyFrames }
    func prepare(sampleRate: Double, maxBlock: Int) {}
    func process(_ input: UnsafePointer<Float>,
                 _ output: UnsafeMutablePointer<Float>,
                 frames: Int) {
        output.update(from: input, count: frames)
    }
    func reset() {}
}
