import XCTest
@testable import GloamVoiceUI

/// A clone recording is checked, not trusted: the script must have been
/// read (or what was said becomes the transcript), and the take must be
/// loud, clean and long enough. Thresholds come from the 2026-09-09 probe
/// of Ryan's ad-lib (hiss) against the voices that work.
final class RecordingCheckTests: XCTestCase {
    private let script = "I'm reading this out loud so the app can learn how I speak. I'll keep it natural, the way I'd talk to a friend, and in a few seconds it should have everything it needs."

    // MARK: script match

    func testTheScriptReadAsWrittenMatchesFully() {
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: script, script: script), 1, accuracy: 0.001)
    }

    func testShanesReadWithSmallRecognitionSlipsPasses() {
        // whisper on Shane's clip: a dropped comma, "I talk" for "I'd talk".
        let heard = "I'm reading this out loud so the app can learn how I speak. I'll keep it natural the way I talk to a friend and in a few seconds it should have everything it needs."
        let m = RecordingCheck.scriptMatch(heard: heard, script: script)
        XCTAssertGreaterThanOrEqual(m, RecordingCheck.matchThreshold, "\(m)")
    }

    func testRyansAdLibFails() {
        let heard = "Alright so we need to fix on this the fact that the logging isn't updated correctly and of course when you go to pay us a lot of money because you should. It should only be $3 and not $2.99."
        let m = RecordingCheck.scriptMatch(heard: heard, script: script)
        XCTAssertLessThan(m, 0.3, "\(m)")
        XCTAssertLessThan(m, RecordingCheck.matchThreshold)
    }

    func testNothingHeardIsZero() {
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "", script: script), 0)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "hello", script: ""), 0)
    }

    // MARK: quality

    private let sr = 24_000

    /// Speech-like: 200 ms bursts of a −16 dBFS tone with a quiet floor between.
    private func take(seconds: Double, speechAmp: Float = 0.16, noiseAmp: Float = 0.0005) -> [Float] {
        var out: [Float] = []
        var rng = SystemRandomNumberGenerator()
        let n = Int(seconds * Double(sr))
        for i in 0..<n {
            let inBurst = (i / (sr / 5)) % 2 == 0
            let tone = inBurst ? speechAmp * Float(sin(Double(i) * 2 * .pi * 220 / Double(sr))) : 0
            let noise = noiseAmp * Float.random(in: -1...1, using: &rng)
            out.append(tone + noise)
        }
        return out
    }

    func testAGoodTakeHasNoProblem() {
        let q = RecordingCheck.measure(take(seconds: 10), sampleRate: sr)
        XCTAssertNil(q.problem, "\(q)")
        XCTAssertGreaterThan(q.speechDb, -20)
        XCTAssertGreaterThan(q.snrDb, 40)
        XCTAssertEqual(q.seconds, 10, accuracy: 0.01)
    }

    func testTooShort() {
        let q = RecordingCheck.measure(take(seconds: 2), sampleRate: sr)
        XCTAssertEqual(q.problem, "That was too short to learn from. Read the whole line, then tap to finish.")
    }

    func testALongTakeIsNotAProblem() {
        // The master may be any reasonable length; each engine picks its own section.
        for seconds in [31.0, 120.0, 290.0] {
            let q = RecordingCheck.measure(take(seconds: seconds), sampleRate: sr)
            XCTAssertNil(q.problem, "\(seconds)s: \(q.problem ?? "nil")")
        }
    }

    func testAPhoneTakeAtMinus37Passes() {
        // −37 dBFS bursts over a −66 floor: what an iPhone 15 Pro mic delivers
        // in measurement mode (no AGC) for normal speech at arm's length
        // (David's take, 2026-09-10: −36.0 / −66.2). Build 15 refused every
        // phone recording as "too quiet" because the floor sat at −25.
        let q = RecordingCheck.measure(take(seconds: 10, speechAmp: 0.02), sampleRate: sr)
        XCTAssertNil(q.problem, "\(q)")
        XCTAssertLessThan(q.speechDb, -30, "\(q)")
    }

    func testTooQuiet() {
        // −51 dBFS bursts: a whisper from across the room, past what levelling can rescue.
        let q = RecordingCheck.measure(take(seconds: 10, speechAmp: 0.004), sampleRate: sr)
        XCTAssertTrue(q.problem?.contains("too quiet") == true, "\(q.problem ?? "nil")")
    }

    func testTooNoisy() {
        // Bursts at −16 dBFS over a noise floor around −30: SNR ~14 dB.
        let q = RecordingCheck.measure(take(seconds: 10, noiseAmp: 0.045), sampleRate: sr)
        XCTAssertLessThan(q.snrDb, RecordingCheck.minSNRDb, "\(q)")
        XCTAssertTrue(q.problem?.contains("background noise") == true, "\(q.problem ?? "nil")")
    }

    func testClipping() {
        var s = take(seconds: 10)
        for i in stride(from: 0, to: s.count, by: 100) { s[i] = 1.0 }   // 1 % of samples pinned
        let q = RecordingCheck.measure(s, sampleRate: sr)
        XCTAssertTrue(q.problem?.contains("clipped") == true, "\(q.problem ?? "nil")")
    }

    func testEmptyIsShortNotACrash() {
        XCTAssertEqual(RecordingCheck.measure([], sampleRate: sr).problem,
                       "That was too short to learn from. Read the whole line, then tap to finish.")
    }
}
