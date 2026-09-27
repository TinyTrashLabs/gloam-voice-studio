import XCTest
@testable import VoiceCreation

final class RecordingCheckTests: XCTestCase {
    func testQuietTakeNamesTheFix() {
        let s = (0..<(24_000 * 5)).map { Float(sin(Double($0) * 0.05) * 0.003) }
        XCTAssertEqual(RecordingCheck.measure(s, sampleRate: 24_000).problem, "That was too quiet — hold the phone closer and speak up a little.")
    }
    func testScriptMatch() { XCTAssertGreaterThan(RecordingCheck.scriptMatch(heard: "the quick brown fox", script: "The quick brown fox."), 0.9) }
    func testCleanupLevelsSpeech() {
        let s = (0..<(24_000 * 4)).map { Float(sin(Double($0) * 0.05) * 0.05) }
        let c = RecordingCleanup.clean(s, sampleRate: 24_000)
        XCTAssertEqual(RecordingCheck.measure(c, sampleRate: 24_000).speechDb, RecordingCleanup.targetSpeechDb, accuracy: 0.5)
    }
}
