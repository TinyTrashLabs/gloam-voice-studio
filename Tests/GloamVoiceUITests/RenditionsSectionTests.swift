import XCTest
@testable import GloamVoiceUI

final class RenditionsSectionTests: XCTestCase {
    func testPaceOverridesLeaveLuxToTheSlider() {
        XCTAssertEqual(RenditionsSection.paceOverrides(nil).map(\.engine), [])
        let rows = RenditionsSection.paceOverrides(["supertonic": 1.08, "lux-tts": 1.2, "chatterbox": 0, "dia2": 0.9])
        XCTAssertEqual(rows.map(\.engine), ["dia2", "supertonic"])
        XCTAssertEqual(rows.map(\.pace), [0.9, 1.08])
    }

}
