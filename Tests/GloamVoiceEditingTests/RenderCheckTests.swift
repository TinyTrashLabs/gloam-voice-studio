import XCTest
@testable import GloamVoiceEditing

final class RenderCheckTests: XCTestCase {
    private let rate = 48000

    /// Speech-like: 200 ms bursts at -16 dBFS with 50 ms gaps.
    private func speech(seconds: Double) -> [Float] {
        let n = Int(seconds * Double(rate))
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            let on = t.truncatingRemainder(dividingBy: 0.25) < 0.2
            return on ? Float(0.2 * sin(2 * .pi * 180 * t)) : 0
        }
    }
    private func hiss(seconds: Double) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -0.002...0.002, using: &g) }
    }
    private let line = "The quick brown fox jumps over the lazy dog near the river bank."   // 64 chars

    func testCleanSpeechAtANormalRatePasses() {
        let s = RenderCheck.signal(speech(seconds: 4.2), sampleRate: rate)   // ~15 chars/s
        XCTAssertEqual(RenderCheck.problems(text: line, signal: s, heard: line), [])
    }

    func testHissIsCaught() {
        let s = RenderCheck.signal(hiss(seconds: 4.2), sampleRate: rate)
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil).contains(.hiss))
    }

    func testDigitalSilenceIsCaught() {
        let s = RenderCheck.signal([Float](repeating: 0, count: rate * 4), sampleRate: rate)
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil).contains(.silent))
    }

    func testClippingIsCaught() {
        var x = speech(seconds: 4.2)
        for i in stride(from: 0, to: x.count, by: 200) { x[i] = 1.0 }
        let s = RenderCheck.signal(x, sampleRate: rate)
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: line).contains(.clipped))
    }

    func testPromptBleedLengthIsTooSlow() {
        // "My voice" 2026-09-11: 123 chars came back 13.56 s (9.1 chars/s) with bleed.
        let s = RenderCheck.signal(speech(seconds: 7.0), sampleRate: rate)   // 64/7 = 9.1
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: line)
            .contains { if case .tooSlow = $0 { return true }; return false })
    }

    func testTruncatedRenderIsTooFast() {
        let s = RenderCheck.signal(speech(seconds: 1.5), sampleRate: rate)   // 43 chars/s
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil)
            .contains { if case .tooFast = $0 { return true }; return false })
    }

    // Finding 3 (final review): the rate band is for pace 1; LuxTTS honours
    // the pace dial, so a slow or fast pace is not a broken render.

    private let isSlow: (RenderProblem) -> Bool = { if case .tooSlow = $0 { return true }; return false }
    private let isFast: (RenderProblem) -> Bool = { if case .tooFast = $0 { return true }; return false }
    private func rate(pace: Float) -> Double {
        RenderCheck.expectedRate(referenceChars: nil, referenceSeconds: nil, pace: pace)
    }

    func testSlowPaceIsNotTooSlow() {
        let s = RenderCheck.signal(speech(seconds: 6.1), sampleRate: rate)   // 64/6.1 = 10.49 chars/s
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil).contains(where: isSlow),
                      "at pace 1 this is flagged -- the case the pace must rescue")
        XCTAssertFalse(RenderCheck.problems(text: line, signal: s, heard: nil, expectedRate: rate(pace: 0.7))
            .contains(where: isSlow))
    }

    func testFastPaceIsNotTooFast() {
        let s = RenderCheck.signal(speech(seconds: 2.37), sampleRate: rate)   // 64/2.37 = 27 chars/s
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil).contains(where: isFast))
        XCTAssertFalse(RenderCheck.problems(text: line, signal: s, heard: nil, expectedRate: rate(pace: 1.8))
            .contains(where: isFast))
    }

    // 2026-09-24: the band follows the voice's own reference rate.

    func testASlowVoiceReadingAtItsOwnPaceIsNotTooSlow() {
        // Morgan: window 11.4 chars/s; David's clean flagged render read 9.6.
        let morgan = RenderCheck.expectedRate(referenceChars: 325, referenceSeconds: 28.5, pace: 1)
        let s = RenderCheck.signal(speech(seconds: 64 / 9.6), sampleRate: rate)
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil).contains(where: isSlow),
                      "the old fixed band flagged it")
        XCTAssertFalse(RenderCheck.problems(text: line, signal: s, heard: nil, expectedRate: morgan)
            .contains(where: isSlow))
    }

    func testAFastVoiceStillFlagsABleedAtThatSameLength() {
        // Jeff reads 17.5 chars/s; 9.6 from him is half his pace.
        let jeff = RenderCheck.expectedRate(referenceChars: 262, referenceSeconds: 15, pace: 1)
        let s = RenderCheck.signal(speech(seconds: 64 / 9.6), sampleRate: rate)
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil, expectedRate: jeff)
            .contains(where: isSlow))
    }

    func testAFastVoiceIsNotTooFastAtItsOwnPace() {
        let jeff = RenderCheck.expectedRate(referenceChars: 262, referenceSeconds: 15, pace: 1)
        let s = RenderCheck.signal(speech(seconds: 64 / 26.5), sampleRate: rate)
        XCTAssertTrue(RenderCheck.problems(text: line, signal: s, heard: nil).contains(where: isFast))
        XCTAssertFalse(RenderCheck.problems(text: line, signal: s, heard: nil, expectedRate: jeff)
            .contains(where: isFast))
    }

    func testASuspectReferenceRateCannotWidenTheBand() {
        // A transcript covering a third of the clip measures ~5 chars/s.
        XCTAssertEqual(RenderCheck.expectedRate(referenceChars: 100, referenceSeconds: 20, pace: 1),
                       RenderCheck.referenceRateRange.lowerBound)
        XCTAssertEqual(RenderCheck.expectedRate(referenceChars: 600, referenceSeconds: 20, pace: 1),
                       RenderCheck.referenceRateRange.upperBound)
    }

    func testMissingWordsAreCaught() {
        let s = RenderCheck.signal(speech(seconds: 4.2), sampleRate: rate)
        let p = RenderCheck.problems(text: line, signal: s, heard: "the quick brown")
        XCTAssertTrue(p.contains { if case .wordsMissing = $0 { return true }; return false })
    }

    func testExtraSpeechIsCaught() {
        let s = RenderCheck.signal(speech(seconds: 4.2), sampleRate: rate)
        let heard = "so anyway what I was saying is " + line + " and then we went home after that"
        let p = RenderCheck.problems(text: line, signal: s, heard: heard)
        XCTAssertTrue(p.contains { if case .extraSpeech = $0 { return true }; return false })
    }

    func testShortPartIgnoresWordMatch() {
        let s = RenderCheck.signal(speech(seconds: 0.4), sampleRate: rate)
        XCTAssertEqual(RenderCheck.problems(text: "Yes.", signal: s, heard: "yeah"), [])
    }

    func testNoTranscriptMeansSignalChecksOnly() {
        let s = RenderCheck.signal(speech(seconds: 4.2), sampleRate: rate)
        XCTAssertEqual(RenderCheck.problems(text: line, signal: s, heard: nil), [])
    }

    func testSeverityPrefersFewerAndMilderProblems() {
        XCTAssertLessThan(RenderCheck.severity([.wordsMissing(match: 0.7)]),
                          RenderCheck.severity([.hiss]))
        XCTAssertEqual(RenderCheck.severity([]), 0)
    }

    func testEnglishDetection() {
        XCTAssertTrue(ScriptLanguage.isEnglish(line))
        XCTAssertFalse(ScriptLanguage.isEnglish("Le renard brun rapide saute par-dessus le chien paresseux."))
    }
}
