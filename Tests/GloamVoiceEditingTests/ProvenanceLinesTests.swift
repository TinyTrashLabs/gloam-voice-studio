import XCTest
import GVoiceKit
@testable import GloamVoiceEditing

final class ProvenanceLinesTests: XCTestCase {
    func testFlattensNestedObjectsAndArraysInKeyOrder() {
        let v: JSONValue = .object([
            "source": .string("gloam-voice-studio-ios-v1-clone"),
            "config": .object(["steps": .number(4), "guidance": .number(3.5), "sharp": .bool(true)]),
            "takes": .array([.string("a.wav"), .string("b.wav")]),
            "note": .null,
        ])
        let lines = ProvenanceLines.flatten(v)
        XCTAssertEqual(lines, [
            .init(key: "config.guidance", value: "3.5"),
            .init(key: "config.sharp", value: "yes"),
            .init(key: "config.steps", value: "4"),
            .init(key: "note", value: "—"),
            .init(key: "source", value: "gloam-voice-studio-ios-v1-clone"),
            .init(key: "takes[0]", value: "a.wav"),
            .init(key: "takes[1]", value: "b.wav"),
        ])
    }

    func testAScalarAtTheTopHasAnEmptyKey() {
        XCTAssertEqual(ProvenanceLines.flatten(.string("x")), [.init(key: "", value: "x")])
    }
}
