import XCTest
@testable import GloamVoiceEditing

final class RenditionsTests: XCTestCase {
    func testPaceOverridesLeaveLuxToTheSlider() {
        XCTAssertEqual(Renditions.paceOverrides(nil).map(\.engine), [])
        let rows = Renditions.paceOverrides(["supertonic": 1.08, "lux-tts": 1.2, "chatterbox": 0, "dia2": 0.9])
        XCTAssertEqual(rows.map(\.engine), ["dia2", "supertonic"])
        XCTAssertEqual(rows.map(\.pace), [0.9, 1.08])
    }
}
