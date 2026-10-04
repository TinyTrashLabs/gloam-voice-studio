import XCTest

@testable import EngineKit

/// Covers the energy cut in LuxReferenceWindow. The ASR half needs an
/// authorized on-device recognizer, so it isn't unit-testable here; the cut is,
/// and both bugs found while building it were in the cut.
final class LuxReferenceWindowTests: XCTestCase {
    private let sampleRate = 24_000

    /// Builds a signal from (seconds, amplitude) segments — amplitude 0 is
    /// silence, anything else stands in for speech.
    private func build(_ segments: [(Double, Float)]) -> [Float] {
        var out: [Float] = []
        for (seconds, amplitude) in segments {
            let count = Int(seconds * Double(sampleRate))
            for i in 0 ..< count {
                let phase = 2 * Float.pi * 220 * Float(i) / Float(sampleRate)
                out.append(amplitude * sin(phase))
            }
        }
        return out
    }

    private func seconds(_ samples: [Float]) -> Double {
        Double(samples.count) / Double(sampleRate)
    }

    /// Peak amplitude over a span of the ORIGINAL clip, for asking "which part
    /// of the recording did the window actually select?".
    private func peak(_ samples: [Float], from: Double, to: Double) -> Float {
        let lo = max(0, Int(from * Double(sampleRate)))
        let hi = min(samples.count, Int(to * Double(sampleRate)))
        guard lo < hi else { return 0 }
        return samples[lo ..< hi].map(abs).max() ?? 0
    }

    func testApproximateTextSlicesOnSentenceEnds() {
        let text = "One two three four. Five six seven eight. Nine ten eleven twelve. Thirteen fourteen fifteen sixteen."
        // A window over the middle half of the audio: the slice starts and stops on whole sentences.
        let out = LuxReferenceWindow.approximateText(text, windowStart: 25_000, windowCount: 50_000, totalCount: 100_000)
        XCTAssertEqual(out, "Five six seven eight. Nine ten eleven twelve.")
    }

    func testPickNeverRefusesALongMaster() async throws {
        let clip = build([(2, 0.5), (0.4, 0), (40, 0.5)])
        let text = (0 ..< 120).map { "w\($0)" }.joined(separator: " ")
        let picked = await LuxReferenceWindow.pick(
            samples: clip, sampleRate: sampleRate, refText: text, maxSeconds: 20)
        let w = try XCTUnwrap(picked)
        XCTAssertLessThanOrEqual(w.seconds, 20.0)
        XCTAssertGreaterThan(w.seconds, 12.0)
        XCTAssertFalse(w.text.isEmpty)
        let fits = await LuxReferenceWindow.pick(
            samples: build([(12, 0.5)]), sampleRate: sampleRate, refText: text, maxSeconds: 20)
        XCTAssertNil(fits, "a clip that fits is not windowed")
    }

    func testLeavesAClipInsideTheWindowAlone() {
        let clip = build([(12, 0.5)])
        let out = LuxReferenceWindow.window(samples: clip, sampleRate: sampleRate, maxSeconds: 30).samples
        XCTAssertEqual(out.count, clip.count)
    }

    func testCapsALongClipAtTheWindow() {
        let out = LuxReferenceWindow.window(
            samples: build([(120, 0.5)]), sampleRate: sampleRate, maxSeconds: 30).samples
        XCTAssertLessThanOrEqual(seconds(out), 30.0)
        XCTAssertGreaterThan(seconds(out), 18.0)
    }

    func testSkipsLeadInSilence() {
        // 8s of silence then speech: a blind head-slice would be a quarter dead.
        let out = LuxReferenceWindow.window(
            samples: build([(8, 0), (100, 0.5)]), sampleRate: sampleRate, maxSeconds: 30).samples
        XCTAssertGreaterThan(peak(out, from: 0.5, to: 25), 0.1)
    }

    /// The bug that made a 58s reference silently window to its LAST 30
    /// seconds: a quiet opening under a floor set by a loud passage later sent
    /// the unbounded onset scan far down the clip, selecting a span the stored
    /// transcript never described.
    func testDoesNotSlideThroughTheClipWhenTheOpeningIsQuiet() {
        // Quiet-but-real speech for 40s, then a much louder passage.
        let clip = build([(40, 0.05), (40, 1.0)])
        let out = LuxReferenceWindow.window(samples: clip, sampleRate: sampleRate, maxSeconds: 30).samples
        // The window must still come from the opening, not the loud tail.
        XCTAssertLessThan(out.map(abs).max() ?? 0, 0.5)
    }

    func testEndsInAPauseRatherThanMidWord() {
        // Speech to 27s, a 1s gap, then speech running past the window.
        let out = LuxReferenceWindow.window(
            samples: build([(27, 0.5), (1, 0), (90, 0.5)]),
            sampleRate: sampleRate, maxSeconds: 30).samples
        XCTAssertGreaterThan(seconds(out), 27.0)
        XCTAssertLessThan(seconds(out), 28.5)
    }

    func testKeepsTheFullWindowWhenTheOnlyPauseWouldCostTooMuchOfIt() {
        let out = LuxReferenceWindow.window(
            samples: build([(5, 0.5), (1, 0), (120, 0.5)]),
            sampleRate: sampleRate, maxSeconds: 30).samples
        XCTAssertEqual(seconds(out), 30.0, accuracy: 0.2)
    }

    func testFadesTheEdgesSoAMidSignalCutDoesNotClick() {
        let out = LuxReferenceWindow.window(
            samples: build([(120, 0.5)]), sampleRate: sampleRate, maxSeconds: 30).samples
        XCTAssertLessThan(abs(out.first ?? 1), 0.01)
        XCTAssertLessThan(abs(out.last ?? 1), 0.01)
    }
}
