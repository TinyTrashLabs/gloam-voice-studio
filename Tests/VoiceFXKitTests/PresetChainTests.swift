import XCTest
@testable import VoiceFXKit

final class PresetChainTests: XCTestCase {
    private func speechLike(_ n: Int, sr: Double = 48_000) -> [Float] {
        // A rough voiced sound: fundamental plus two harmonics, amplitude
        // modulated. Closer to speech than a sine, which matters for formant work.
        (0..<n).map { i in
            let t = Double(i) / sr
            let env = 0.5 + 0.5 * sin(2 * Double.pi * 3 * t)
            let s = sin(2 * Double.pi * 180 * t)
                  + 0.5 * sin(2 * Double.pi * 360 * t)
                  + 0.25 * sin(2 * Double.pi * 540 * t)
            return Float(env * s * 0.3)
        }
    }

    /// THE test. Whole-buffer output must equal chunked output, sample for
    /// sample, for every preset. This is what makes the streaming path safe
    /// by construction rather than by inspection.
    func testEveryPresetIsChunkInvariant() throws {
        let input = speechLike(24_000)
        for name in FXPreset.builtInNames {
            let preset = try XCTUnwrap(FXPreset.builtIn(named: name))

            let whole = FXChain.make(from: preset)
            whole.prepare(sampleRate: 48_000, maxBlock: 24_000)
            let expected = whole.applyWhole(input)

            let chunked = FXChain.make(from: preset)
            chunked.prepare(sampleRate: 48_000, maxBlock: 24_000)
            var actual = [Float](repeating: 0, count: input.count)
            var i = 0
            input.withUnsafeBufferPointer { inBuf in
                actual.withUnsafeMutableBufferPointer { o in
                    for size in [256, 1024, 64, 4096, 512, 18_048] {
                        let n = min(size, input.count - i)
                        if n <= 0 { break }
                        chunked.process(inBuf.baseAddress! + i, o.baseAddress! + i, frames: n)
                        i += n
                    }
                }
            }
            XCTAssertEqual(i, input.count)
            for k in 0..<i {
                XCTAssertEqual(actual[k], expected[k], accuracy: 1e-4,
                               "\(name) diverged at sample \(k)")
            }
        }
    }

    func testEveryPresetProducesFiniteAudioWithinCeiling() throws {
        let input = speechLike(24_000)
        for name in FXPreset.builtInNames {
            let preset = try XCTUnwrap(FXPreset.builtIn(named: name))
            let chain = FXChain.make(from: preset)
            chain.prepare(sampleRate: 48_000, maxBlock: 24_000)
            let out = chain.applyWhole(input)
            XCTAssertTrue(out.allSatisfy { $0.isFinite }, "\(name) produced non-finite audio")
            let ceiling = preset.limiter?.ceiling ?? 1.0
            XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, ceiling + 1e-3,
                                     "\(name) exceeded its ceiling")
        }
    }

    func testEveryPresetProducesAudibleOutput() throws {
        let input = speechLike(24_000)
        for name in FXPreset.builtInNames {
            let preset = try XCTUnwrap(FXPreset.builtIn(named: name))
            let chain = FXChain.make(from: preset)
            chain.prepare(sampleRate: 48_000, maxBlock: 24_000)
            let out = chain.applyWhole(input)
            let tail = Array(out[(out.count / 2)...])
            let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
            XCTAssertGreaterThan(rms, 0.005, "\(name) is effectively silent")
        }
    }

    func testEveryPresetReportsLatency() throws {
        for name in FXPreset.builtInNames {
            let preset = try XCTUnwrap(FXPreset.builtIn(named: name))
            let chain = FXChain.make(from: preset)
            chain.prepare(sampleRate: 48_000, maxBlock: 4096)
            // Presets with a pitch stage must declare real latency; this is the
            // number the streaming work needs, so it must not be silently zero.
            if preset.pitch != nil {
                XCTAssertGreaterThan(chain.latencyFrames, 0, "\(name) reported no latency")
            }
            print("[latency] \(name): \(chain.latencyFrames) frames "
                  + "(\(Double(chain.latencyFrames) / 48_000 * 1000) ms @ 48k)")
        }
    }

    /// A preset with a `detune` section but no `pitch` section must still get
    /// a detuned voice in the chain (summed with the dry pass-through), not
    /// have the branch silently dropped.
    func testDetuneWithoutPitchStillProducesDetunedVoice() throws {
        let json = """
        {
          "version": 1,
          "name": "detune-only",
          "detune": {
            "transposeSemitones": 7,
            "formantSemitones": 0,
            "formantBaseHz": 0,
            "gain": 0.8
          },
          "limiter": { "ceiling": 0.98, "releaseSeconds": 0.05 }
        }
        """
        let preset = try JSONDecoder().decode(FXPreset.self, from: Data(json.utf8))
        XCTAssertNotNil(preset.detune)
        XCTAssertNil(preset.pitch)

        let chain = FXChain.make(from: preset)
        chain.prepare(sampleRate: 48_000, maxBlock: 24_000)
        let input = speechLike(24_000)
        let out = chain.applyWhole(input)

        // A dry pass-through alone (no detune branch) would be identical to
        // the (limited) input; the detuned voice summed in must change it.
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        var maxDiff: Float = 0
        for k in 0..<out.count {
            maxDiff = max(maxDiff, abs(out[k] - input[k]))
        }
        XCTAssertGreaterThan(maxDiff, 0.01, "detune-only preset produced output indistinguishable from dry input")
    }

    /// Finding 1: the pitch shifter's declared latency must be compensated,
    /// not just logged, or a short/tightly-trimmed line loses its tail.
    /// Builds a signal silent for its first half then a loud burst, runs it
    /// through a pitch-bearing preset with latency compensation applied, and
    /// asserts the burst's onset in the output lands close to its onset in
    /// the input (rather than shifted late by ~latencyFrames, or with the
    /// tail chopped off by the plain `applyWhole`).
    func testLatencyCompensationPreservesOnsetAlignment() throws {
        let sr = 48_000.0
        let n = 24_000
        let halfway = n / 2
        var input = [Float](repeating: 0, count: n)
        for i in halfway..<n {
            let t = Double(i - halfway) / sr
            input[i] = Float(sin(2 * Double.pi * 220 * t) * 0.8)
        }

        let preset = try XCTUnwrap(FXPreset.builtIn(named: "demon"))
        XCTAssertNotNil(preset.pitch, "demon preset must carry a pitch stage for this test to be meaningful")

        let chain = FXChain.make(from: preset)
        chain.prepare(sampleRate: sr, maxBlock: n)
        XCTAssertGreaterThan(chain.latencyFrames, 0)

        let out = chain.applyWholeLatencyCompensated(input)
        XCTAssertEqual(out.count, input.count)

        // Find the first sample in the output whose magnitude clears a
        // threshold well above noise floor — that's the burst's onset.
        let threshold: Float = 0.05
        let onset = out.firstIndex { abs($0) > threshold }
        let onsetIndex = try XCTUnwrap(onset, "no burst detected in compensated output")

        // Without compensation the onset would land ~latencyFrames late (or,
        // with the naive un-trimmed approach, the tail could be missing
        // entirely). Allow a small tolerance for filter ringing/smearing.
        let tolerance = 2_400 // 50 ms @ 48k
        XCTAssertLessThan(abs(onsetIndex - halfway), tolerance,
                          "burst onset at \(onsetIndex) is not aligned with input onset at \(halfway)")
    }

    func testResetClearsTailsBetweenUtterances() throws {
        let preset = try XCTUnwrap(FXPreset.builtIn(named: "demon"))
        let chain = FXChain.make(from: preset)
        chain.prepare(sampleRate: 48_000, maxBlock: 4800)
        let input = speechLike(4800)
        let first = chain.applyWhole(input)
        chain.reset()
        let second = chain.applyWhole(input)
        for k in 0..<input.count {
            XCTAssertEqual(first[k], second[k], accuracy: 1e-4,
                           "reset did not restore initial state (sample \(k))")
        }
    }
}
