import XCTest
@testable import GVoiceKit

final class ReferenceStandardPathTests: XCTestCase {
    func testVoiceAndTakeReferencesAreReferences() {
        for path in ["ref.wav", "source/ref.wav", "engines/lux-tts/ref.wav",
                     "source/ref-excited.wav", "source/ref-es.wav", "source/ref-es-hype.wav"] {
            XCTAssertTrue(ReferenceStandard.isReference(path: path), path)
        }
    }

    func testOtherMembersAreNot() {
        for path in ["manifest.json", "avatar.png", "source/ref-.wav", "source/ref.txt",
                     "source/ref-excited.txt", "engines/qwen3-0.6b/ref_codes.npy", "source/preview.wav", "ref.wav.bak"] {
            XCTAssertFalse(ReferenceStandard.isReference(path: path), path)
        }
    }
}
