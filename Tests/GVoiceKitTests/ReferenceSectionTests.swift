import XCTest
@testable import GVoiceKit

final class ReferenceSectionTests: XCTestCase {
    private let sr = 24_000

    /// Speech-like: 0.6 s bursts with 0.3 s pauses, so the cut has pauses to end in.
    static func speech(seconds: Double, sampleRate: Int = 24_000) -> [Float] {
        (0 ..< Int(seconds * Double(sampleRate))).map { i in
            let t = Double(i) / Double(sampleRate)
            let burst = t.truncatingRemainder(dividingBy: 0.9) < 0.6
            return burst ? 0.3 * Float(sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 540 * t)) : 0
        }
    }

    func testStoredSectionBytesAreAFixedPointOfTheReferenceStandard() {
        // Import applies the standard to every engine wav; a section written already at the standard
        // must come through byte for byte, or the hashes recorded beside it would go stale.
        let cut = ReferenceSection.cut(samples: Self.speech(seconds: 60), sampleRate: sr, maxSeconds: 20)
        let wav = ReferenceSection.wavData(cut.samples, sampleRate: sr)
        XCTAssertEqual(ReferenceStandard.applied(to: wav), wav)
        XCTAssertLessThanOrEqual(cut.samples.count, 20 * sr)
        XCTAssertGreaterThan(cut.samples.count, 12 * sr)
    }

    func testTextIsTheHeardWordsWhenPlausibleElseTheMastersOwnSlice() {
        let master = "One two three four. Five six seven eight. Nine ten eleven twelve. Thirteen fourteen fifteen sixteen."
        let heard = (0 ..< 30).map { "w\($0)" }.joined(separator: " ")
        let a = ReferenceSection.text(heard: heard, transcript: master, cutSeconds: 10, start: 25_000, count: 50_000, total: 100_000)
        XCTAssertEqual(a.text, heard); XCTAssertFalse(a.approximate)
        let b = ReferenceSection.text(heard: "hm", transcript: master, cutSeconds: 10, start: 25_000, count: 50_000, total: 100_000)
        XCTAssertEqual(b.text, "Five six seven eight. Nine ten eleven twelve."); XCTAssertTrue(b.approximate)
        let c = ReferenceSection.text(heard: nil, transcript: master, cutSeconds: 10, start: 25_000, count: 50_000, total: 100_000)
        XCTAssertTrue(c.approximate)
    }

    func testWordDistanceIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(ReferenceSection.wordDistance(heard: "ha sido complicado en especifico", text: "Ha sido complicado en específico."), 0)
        XCTAssertEqual(ReferenceSection.wordDistance(heard: "en específico. Yo creo que", text: "en específico."), 3)
        XCTAssertEqual(ReferenceSection.wordDistance(heard: "", text: "uno dos"), 2)
        XCTAssertEqual(ReferenceSection.wordDistance(heard: "uno dos", text: ""), 2)
    }

    func testSentenceEndCandidatesEndInPausesAtSentenceEnds() {
        let x = Self.speech(seconds: 18)              // 20 bursts, a 0.3 s pause after each
        let text = (0 ..< 20).map { $0 % 4 == 3 ? "w\($0)." : "w\($0)" }.joined(separator: " ")
        let c = ReferenceSection.sentenceEndCandidates(samples: x, text: text, sampleRate: sr)
        XCTAssertFalse(c.isEmpty)
        for cand in c {
            XCTAssertTrue(ReferenceSection.endsSentence(cand.text), cand.text)
            XCTAssertGreaterThanOrEqual(cand.samples.count, 5 * sr)
            // each cut ends inside a pause: its last 50 ms (before the fade) is silent
            let tail = cand.samples[(cand.samples.count - 1200) ..< (cand.samples.count - 240)]
            XCTAssertLessThan(tail.map { abs($0) }.max() ?? 1, 0.01)
        }
        // the true end of the 16th word ("w15.") is among them
        XCTAssertTrue(c.contains { $0.text.hasSuffix("w15.") && abs(Double($0.samples.count) / Double(sr) - 14.2) < 0.05 })
    }
}
