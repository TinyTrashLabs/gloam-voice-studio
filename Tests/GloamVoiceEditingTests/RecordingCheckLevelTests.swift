import XCTest
@testable import GloamVoiceEditing

/// The "too quiet" gate judges the voice, not the pauses around it.
final class RecordingCheckLevelTests: XCTestCase {
    private let sr = 24_000

    /// `seconds` of a tone whose RMS is `db` dBFS.
    private func tone(_ seconds: Double, db: Float, hz: Float) -> [Float] {
        let amp = powf(10, db / 20) * 2.0.squareRoot().float
        return (0..<Int(seconds * Double(sr))).map { amp * sinf(2 * .pi * hz * Float($0) / Float(sr)) }
    }

    func testNormalVoiceWithLongPausesIsNotTooQuiet() {
        // 3 s of voice at a normal phone level, 7 s of room tone around it:
        // the louder half of the whole take is mostly silence.
        let take = tone(2, db: -66, hz: 3000) + tone(3, db: -36, hz: 220) + tone(5, db: -66, hz: 3000)
        let q = RecordingCheck.measure(take, sampleRate: sr)
        XCTAssertLessThan(q.speechDb, -45, "the old whole-take measure would have refused this at the old -45 floor")
        XCTAssertEqual(q.gateDb, -36, accuracy: 1)
        XCTAssertNil(q.problem)
    }

    /// David's close-to-the-phone take (2026-10-06): voiced −45.5 over a −71
    /// floor. Clean; levelling lifts it. It was refused by half a decibel.
    func testAQuietButCleanPhoneTakePasses() {
        let take = tone(1, db: -71, hz: 3000) + tone(10, db: -45.5, hz: 220) + tone(1.5, db: -71, hz: 3000)
        let q = RecordingCheck.measure(take, sampleRate: sr)
        XCTAssertEqual(q.gateDb, -45.5, accuracy: 1)
        XCTAssertNil(q.problem, "\(q)")
    }

    func testGenuinelyQuietTakeIsStillRefused() {
        let take = tone(1, db: -70, hz: 3000) + tone(6, db: -52, hz: 220) + tone(1, db: -70, hz: 3000)
        let q = RecordingCheck.measure(take, sampleRate: sr)
        XCTAssertEqual(q.problem, "That was too quiet — hold the phone closer and speak up a little.")
    }
}

private extension Double { var float: Float { Float(self) } }
