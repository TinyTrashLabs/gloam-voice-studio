import XCTest
@testable import GloamVoiceUI

final class TakeCombinerTests: XCTestCase {
    private let sr = 24_000

    func testClipsAreLevelledJoinedWithAGapAndTranscriptsFollow() {
        let quiet = [Float](repeating: 0.1, count: sr)      // 1 s at 0.1
        let loud = [Float](repeating: 0.5, count: sr / 2)   // 0.5 s at 0.5
        let (samples, text) = TakeCombiner.combine([(quiet, " one "), (loud, "two"), ([0.2], "")], sampleRate: sr)
        let gap = Int(Double(sr) * TakeCombiner.gapSeconds)
        XCTAssertEqual(samples.count, sr + gap + sr / 2 + gap + 1)
        XCTAssertEqual(samples[0], TakeCombiner.peakTarget, accuracy: 1e-4, "the quiet clip is brought up")
        XCTAssertEqual(samples[sr + gap], TakeCombiner.peakTarget, accuracy: 1e-4, "and the loud one to the same peak")
        XCTAssertEqual(samples[sr + gap / 2], 0, "silence between")
        XCTAssertEqual(text, "one two", "empty transcripts are dropped, the rest trimmed and joined")
    }

    func testSilenceIsLeftAlone() {
        XCTAssertEqual(TakeCombiner.normalizePeak([0, 0, 0]), [0, 0, 0])
        XCTAssertEqual(TakeCombiner.normalizePeak([]), [])
    }

    // MARK: rules

    private func quality(seconds: Double, speech: Float = -16, floor: Float = -60, clipped: Double = 0) -> RecordingCheck.Quality {
        RecordingCheck.Quality(seconds: seconds, speechDb: speech, noiseFloorDb: floor, clippedFraction: clipped)
    }

    func testOnlyTooShortIsAnError() {
        XCTAssertEqual(TakeRules.verdict(for: quality(seconds: 6)), .good)
        if case .error = TakeRules.verdict(for: quality(seconds: 2.9)) {} else { XCTFail("short take must block") }
        XCTAssertEqual(TakeRules.verdict(for: quality(seconds: 6, speech: -36)), .good, "a normal phone take is not quiet")
        if case .warning = TakeRules.verdict(for: quality(seconds: 6, speech: -50)) {} else { XCTFail("quiet is a warning") }
        if case .warning = TakeRules.verdict(for: quality(seconds: 6, floor: -20)) {} else { XCTFail("noise is a warning") }
        if case .warning = TakeRules.verdict(for: quality(seconds: 6, clipped: 0.01)) {} else { XCTFail("clipping is a warning") }
    }

    func testCombinedLengthCountsTheGaps() {
        XCTAssertEqual(TakeRules.combinedSeconds([]), 0)
        XCTAssertEqual(TakeRules.combinedSeconds([10]), 10)
        XCTAssertEqual(TakeRules.combinedSeconds([10, 5, 5]), 20.5, accuracy: 1e-9)
    }

    func testShortTakeBlocksSaveWarningsDoNot() {
        XCTAssertNotNil(TakeRules.saveBlocker(verdicts: [], combinedSeconds: 0))
        XCTAssertNil(TakeRules.saveBlocker(verdicts: [.good, .warning("noisy")], combinedSeconds: 12))
        XCTAssertNotNil(TakeRules.saveBlocker(verdicts: [.good, .error("short")], combinedSeconds: 12))
        XCTAssertNil(TakeRules.saveBlocker(verdicts: [.good], combinedSeconds: 290),
                     "a long master is fine: each engine picks its own section")
    }

    func testCountLineSaysWhatSaveWillDo() {
        XCTAssertNil(TakeRules.countLine(count: 0, combinedSeconds: 0, stale: false, blocker: nil))
        XCTAssertEqual(TakeRules.countLine(count: 1, combinedSeconds: 4.4, stale: false, blocker: nil), "1 take · 0:04")
        XCTAssertEqual(TakeRules.countLine(count: 2, combinedSeconds: 19.2, stale: true, blocker: nil), "2 takes · 0:19 · Save rebuilds the master")
        XCTAssertEqual(TakeRules.countLine(count: 2, combinedSeconds: 65, stale: true, blocker: "too long"), "2 takes · 1:05 · too long")
    }

    func testLengthLineStatesTheLengthAndNoCap() {
        XCTAssertEqual(TakeRules.lengthLine(combinedSeconds: 12), "12s of takes.")
        for seconds in [24.0, 31.0, 200.0] {
            let line = TakeRules.lengthLine(combinedSeconds: seconds).lowercased()
            XCTAssertFalse(line.contains("cap") || line.contains("over") || line.contains("window"), line)
        }
    }
}
