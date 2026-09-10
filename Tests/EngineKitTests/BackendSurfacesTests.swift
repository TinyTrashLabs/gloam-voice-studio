import XCTest
@testable import EngineKit

/// The surfaces map is the reason a newly added backend can't go missing from
/// the UI. These tests pin the invariants a `switch` alone can't state.
final class BackendSurfacesTests: XCTestCase {
    func testEveryBackendAppearsSomewhere() {
        for backend in BackendID.allCases {
            XCTAssertFalse(backend.surfaces.isEmpty,
                           "\(backend.rawValue) is declared but invisible everywhere")
        }
    }

    /// The bug that motivated this: dia2 shipped downloadable nowhere, while
    /// the Dialogue screen told people to get it in Settings → Models.
    func testAnythingSelectableIsAlsoInstallable() {
        for backend in BackendID.allCases where !backend.surfaces.isDisjoint(
            with: [.studio, .dialogue, .creation, .chatVoice, .apiServer]
        ) {
            XCTAssertTrue(backend.surfaces.contains(.downloadable),
                          "\(backend.rawValue) can be picked but never downloaded")
        }
    }

    /// Dia2 is Dialogue-only, not a Studio single-line engine: a single S1-only
    /// prefix clones the target voice too weakly to ship (conditioning is applied
    /// but the voice is wrong — inherent, see issue #56). It stays downloadable
    /// and on the Dialogue screen.
    func testDia2IsDialogueOnlyNotInStudio() {
        XCTAssertFalse(BackendID.on(.studio).contains(.dia2))
        XCTAssertTrue(BackendID.on(.dialogue).contains(.dia2))
        XCTAssertTrue(BackendID.on(.downloadable).contains(.dia2))
    }

    /// qwen3-design mints a voice from an instruct per line — it can neither be
    /// the Studio speak-backend nor answer chat unattended.
    func testDesignBackendStaysOutOfStudioAndChat() {
        XCTAssertFalse(BackendID.on(.studio).contains(.qwenDesign))
        XCTAssertFalse(BackendID.on(.chatVoice).contains(.qwenDesign))
        XCTAssertTrue(BackendID.on(.creation).contains(.qwenDesign))
    }

    /// Dia2 needs its prefix aligned first, which is not an unattended step.
    func testDia2IsNotAChatVoice() {
        XCTAssertFalse(BackendID.on(.chatVoice).contains(.dia2))
    }

    /// Only one dialogue engine exists; `GloamEngine.performSynthesis` routes on
    /// this flag, so anything declaring it must actually speak dialogue.
    func testOnlyDia2DeclaresDialogue() {
        XCTAssertEqual(BackendID.on(.dialogue), [.dia2])
    }

    /// Declaration order is presentation order — the picker's priority ordering
    /// now lives in the enum instead of a curated array.
    func testPickerOrderPutsCloningQwenFirstAndDemotesChatterbox() {
        let studio = BackendID.on(.studio)
        XCTAssertEqual(studio.first, .qwen06B)
        XCTAssertLessThan(studio.firstIndex(of: .chatterboxTurbo)!,
                          studio.firstIndex(of: .chatterbox)!)
        XCTAssertLessThan(studio.firstIndex(of: .fishS2Pro)!,
                          studio.firstIndex(of: .chatterbox)!)
    }
}
