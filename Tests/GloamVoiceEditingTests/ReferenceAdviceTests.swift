import XCTest
@testable import GloamVoiceEditing

final class ReferenceAdviceTests: XCTestCase {
    private func q(seconds: Double = 12, speech: Float = -18, floor: Float = -60, clipped: Double = 0) -> RecordingCheck.Quality {
        .init(seconds: seconds, speechDb: speech, noiseFloorDb: floor, clippedFraction: clipped)
    }
    private let text = String(repeating: "a", count: 190)   // 190 chars / 12 s = 15.8 chars/s, healthy

    func testAHealthyRecordingHasNoFindings() {
        XCTAssertEqual(ReferenceAdvice.findings(quality: q(), refText: text), [])
    }
    func testNoiseSuggestsCleanup() {
        XCTAssertEqual(ReferenceAdvice.findings(quality: q(floor: -40), refText: text).map(\.fix), [.cleanUpNoise])
    }
    func testASlowTranscriptRateSuggestsFixingTheTranscript() {
        // 11.2 chars/s: David's take whose transcript missed its tail (2026-09-11).
        let f = ReferenceAdvice.findings(quality: q(), refText: String(repeating: "a", count: 134))
        XCTAssertEqual(f.map(\.fix), [.fixTranscript])
    }
    func testAShortRecordingSuggestsReRecording() {
        XCTAssertEqual(ReferenceAdvice.findings(quality: q(seconds: 5), refText: String(repeating: "a", count: 79)).map(\.fix), [.reRecord])
    }
    func testClippingSuggestsReRecording() {
        XCTAssertTrue(ReferenceAdvice.findings(quality: q(clipped: 0.01), refText: text).map(\.fix).contains(.reRecord))
    }

    /// The clone-time check stores findings as their messages (the sidecar);
    /// Compose turns them back into a finding with its button.
    func testEveryFindingsMessageMapsBackToItsFix() {
        let cases: [(RecordingCheck.Quality, String)] = [
            (q(floor: -40), text),
            (q(), String(repeating: "a", count: 134)),
            (q(seconds: 5), String(repeating: "a", count: 79)),
            (q(clipped: 0.01), text),
        ]
        var seen = Set<String>()
        for (quality, refText) in cases {
            for f in ReferenceAdvice.findings(quality: quality, refText: refText) {
                XCTAssertEqual(ReferenceAdvice.Finding(storedMessage: f.message), f, f.message)
                seen.insert("\(f.fix)")
            }
        }
        XCTAssertEqual(seen.count, 3, "every kind of fix is covered")
        XCTAssertNil(ReferenceAdvice.Finding(storedMessage: "Something a later build says."))
    }
}
