import XCTest
@testable import GloamVoiceEditing

/// The recording meter reads in dB, so a normal voice fills it.
final class CloneRecorderMeterTests: XCTestCase {
    private func rms(_ db: Float) -> Float { powf(10, db / 20) }

    func testNormalPhoneSpeechFillsAboutTwoThirds() {
        XCTAssertEqual(CloneRecorder.meterLevel(rms: rms(-36), previous: 0), 0.6, accuracy: 0.01)
    }

    func testEnds() {
        XCTAssertEqual(CloneRecorder.meterLevel(rms: rms(-60), previous: 0), 0, accuracy: 1e-4)
        XCTAssertEqual(CloneRecorder.meterLevel(rms: rms(-10), previous: 0), 1)
        XCTAssertEqual(CloneRecorder.meterLevel(rms: 0, previous: 0), 0)
    }

    func testRisesAtOnceAndFallsSlowly() {
        XCTAssertEqual(CloneRecorder.meterLevel(rms: rms(-20), previous: 0.1), 1)
        XCTAssertEqual(CloneRecorder.meterLevel(rms: 0, previous: 1), 0.82, accuracy: 1e-4)
    }
}
