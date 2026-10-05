import XCTest
import GVoiceKit
@testable import GloamVoiceEditing

final class UserFacingErrorTests: XCTestCase {
    func testNothingToInstallMapsToAPlainSentence() {
        let error = StudioError.invalidArchive("archive has no base variant to install")
        XCTAssertEqual(userMessage(for: error), "This pack has nothing to install.")
    }

    func testUnrecognizedArchiveMapsToAPlainSentence() {
        let error = StudioError.invalidArchive("not a valid .gvoice archive: corrupt zip")
        XCTAssertEqual(userMessage(for: error), "This file isn't a voice pack.")
    }

    func testVoiceExistsMapsToAPlainSentence() {
        XCTAssertEqual(userMessage(for: StudioError.voiceExists(slug: "jeff")),
                       "A voice with that name already exists.")
    }

    func testInvalidNameMapsToAPlainSentence() {
        XCTAssertEqual(userMessage(for: StudioError.invalidName("!!!")),
                       "That name can't be used for a voice.")
    }

    func testInvalidRefAudioMapsToAPlainSentence() {
        XCTAssertEqual(userMessage(for: StudioError.invalidRefAudio("decoded to nothing")),
                       "The reference recording couldn't be read.")
    }

    func testPackTooLargeMapsToAPlainSentence() {
        XCTAssertEqual(userMessage(for: VoiceStoreError.unreadableImage),
                       "That picture couldn't be read.")
        XCTAssertEqual(userMessage(for: VoiceStoreError.packTooLarge),
                       "This voice pack is too large to import (limit 64 MB).")
    }

    /// Anything not specially handled falls back to the error's own description.
    func testFallbackUsesLocalizedDescription() {
        struct OtherError: LocalizedError {
            var errorDescription: String? { "Something unrelated went wrong." }
        }
        XCTAssertEqual(userMessage(for: OtherError()), "Something unrelated went wrong.")
    }
}
