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
}
