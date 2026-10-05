import XCTest
@testable import GloamVoiceEditing

final class RecordingCleanupTests: XCTestCase {
    private let sr = 24_000

    private func tone(seconds: Double, amp: Float) -> [Float] {
        (0..<Int(seconds * Double(sr))).map { amp * Float(sin(Double($0) * 2 * .pi * 220 / Double(sr))) }
    }
    private func silence(seconds: Double) -> [Float] { [Float](repeating: 0.0002, count: Int(seconds * Double(sr))) }

    func testTrimCutsBothEndsButKeepsAPad() {
        let s = silence(seconds: 2) + tone(seconds: 3, amp: 0.2) + silence(seconds: 1.5)
        let t = RecordingCleanup.trim(s, sampleRate: sr)
        let expected = 3 + 2 * RecordingCleanup.padSeconds
        XCTAssertEqual(Double(t.count) / Double(sr), expected, accuracy: 0.06)
    }

    func testTrimLeavesAnAllSilentTakeAlone() {
        let s = silence(seconds: 4)
        XCTAssertEqual(RecordingCleanup.trim(s, sampleRate: sr).count, s.count)
    }

    func testLevelBringsAQuietTakeUpToTarget() {
        // Ryan-like: a tone at about −28 dBFS RMS.
        let quiet = tone(seconds: 5, amp: 0.056)
        let out = RecordingCleanup.level(quiet, sampleRate: sr)
        let q = RecordingCheck.measure(out, sampleRate: sr)
        XCTAssertEqual(q.speechDb, RecordingCleanup.targetSpeechDb, accuracy: 0.5)
    }

    func testLevelBringsALoudTakeDown() {
        let loud = tone(seconds: 5, amp: 0.9)
        let q = RecordingCheck.measure(RecordingCleanup.level(loud, sampleRate: sr), sampleRate: sr)
        XCTAssertEqual(q.speechDb, RecordingCleanup.targetSpeechDb, accuracy: 0.5)
    }

    func testLevelNeverPushesAPeakPastTheCeiling() {
        // Quiet overall but with one hot sample: the peak wins.
        var s = tone(seconds: 5, amp: 0.03)
        s[1000] = 0.5
        let out = RecordingCleanup.level(s, sampleRate: sr)
        XCTAssertLessThanOrEqual(out.reduce(0) { max($0, abs($1)) }, RecordingCleanup.peakCeiling + 0.001)
    }

    func testCleanIsTrimThenLevelAndPassesTheQualityCheck() {
        // Speech-like: quiet bursts with pauses, padded by room silence.
        var speech: [Float] = []
        for _ in 0..<6 { speech += tone(seconds: 0.7, amp: 0.05) + silence(seconds: 0.3) }
        let s = silence(seconds: 1) + speech + silence(seconds: 1)
        let out = RecordingCleanup.clean(s, sampleRate: sr)
        // 6 s of speech minus the last 0.3 s pause, plus the two pads.
        XCTAssertEqual(Double(out.count) / Double(sr), 5.7 + 2 * RecordingCleanup.padSeconds, accuracy: 0.1)
        let q = RecordingCheck.measure(out, sampleRate: sr)
        XCTAssertNil(q.problem, "\(q)")
        XCTAssertEqual(q.speechDb, RecordingCleanup.targetSpeechDb, accuracy: 1.5)
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertEqual(RecordingCleanup.clean([], sampleRate: sr), [])
    }
}
