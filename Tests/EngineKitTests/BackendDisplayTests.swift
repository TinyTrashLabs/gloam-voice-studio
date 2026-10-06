import XCTest
@testable import EngineKit

final class BackendDisplayTests: XCTestCase {
    func testDisplayNamesAreHumanAndUnique() {
        XCTAssertEqual(BackendID.qwen06B.displayName, "Qwen 0.6B")
        XCTAssertEqual(BackendID.qwen06BMobile.displayName, "Qwen 0.6B Mobile")
        XCTAssertEqual(BackendID.qwen06BANE.displayName, "Qwen 0.6B ANE")
        XCTAssertEqual(BackendID.breezeTTS2.displayName, "Breeze")
        XCTAssertEqual(BackendID.pocketTTS.displayName, "Pocket")
        let names = BackendID.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "two engines share a display name")
        for backend in BackendID.allCases {
            XCTAssertNotEqual(backend.displayName, backend.rawValue)
            XCTAssertFalse(backend.displayName.contains("-"), "\(backend) display name has an id-style hyphen")
        }
    }

    func testFamilyName() {
        XCTAssertEqual(BackendID.chatterboxTurbo.familyName, "Chatterbox")
        XCTAssertEqual(BackendID.qwenCustom.familyName, "Qwen")
        XCTAssertEqual(BackendID.kokoro.familyName, "Kokoro")
    }

    func testEveryStudioEngineHasAPreferenceRank() {
        for backend in BackendID.on(.studio) {
            XCTAssertTrue(BackendID.autoSwitchPreference.contains(backend),
                          "\(backend.rawValue) missing from autoSwitchPreference")
        }
    }

    func testNoSwitchWhenCurrentCanSpeak() {
        XCTAssertNil(BackendID.autoSwitchTarget(current: .qwen06B, candidates: [.qwen06B, .qwen17B],
                                                recent: [.qwen17B]))
    }

    func testNoSwitchWhenNothingCanSpeak() {
        XCTAssertNil(BackendID.autoSwitchTarget(current: .kokoro, candidates: [], recent: [.qwen06B]))
    }

    func testMostRecentCompatibleWins() {
        let target = BackendID.autoSwitchTarget(
            current: .kokoro,
            candidates: [.qwen17B, .qwen06B, .chatterbox],
            recent: [.kokoro, .supertonic, .chatterbox, .qwen06B])
        XCTAssertEqual(target, .chatterbox)
    }

    func testPreferenceOrderWithoutHistory() {
        let target = BackendID.autoSwitchTarget(
            current: .kokoro, candidates: [.luxTTS, .chatterbox, .qwen06B], recent: [.kokoro])
        XCTAssertEqual(target, .qwen06B)
    }

    func testPreRenderedBeatsCloneWithoutHistory() {
        // A Kokoro preset voice while a cloner is selected: the pack's own
        // engine is the right switch, not a cloner that has nothing to clone.
        let target = BackendID.autoSwitchTarget(
            current: .qwen06B, candidates: [.kokoro, .qwen17B], recent: [],
            preRendered: [.kokoro])
        XCTAssertEqual(target, .kokoro)
    }

    func testRecordingRecentDedupesAndCaps() {
        let r = BackendID.recordingRecent(.kokoro, in: [.qwen06B, .kokoro, .luxTTS], limit: 3)
        XCTAssertEqual(r, [.kokoro, .qwen06B, .luxTTS])
        XCTAssertEqual(BackendID.recordingRecent(.dia2, in: r, limit: 3), [.dia2, .kokoro, .qwen06B])
    }
}
