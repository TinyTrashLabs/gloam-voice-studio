import XCTest
@testable import GloamVoiceEditing

final class EmotionVersionsTests: XCTestCase {
    func testVariantSlugAndNameFollowTheLibraryRule() {
        XCTAssertEqual(EmotionVersions.slug(base: "benson", key: "hype"), "benson-hype")
        XCTAssertEqual(EmotionVersions.name(base: "Benson", key: "hype"), "Benson hype")
    }

    func testAvailableLeavesOutRecordedEmotions() {
        XCTAssertEqual(EmotionVersions.available(existingKeys: []), EmotionOption.studio)
        XCTAssertEqual(EmotionVersions.available(existingKeys: ["hype", "warm"]).map(\.key), ["flat", "neutral", "excited"])
        XCTAssertEqual(EmotionVersions.available(existingKeys: ["flat", "neutral", "warm", "excited", "hype"]), [])
    }

    func testTheScriptIsTheDesktopsWordForWord() {
        XCTAssertTrue(EmotionScript.passage.hasPrefix("The old lighthouse keeper climbed the spiral stairs every evening, counting each of the two hundred steps out loud."))
        XCTAssertTrue(EmotionScript.passage.hasSuffix("before he was born and would be for a hundred after he was gone."))
        XCTAssertEqual(EmotionScript.passage.split(separator: " ").count, 83)
        XCTAssertEqual(EmotionScript.deliveryNote(for: "hype"), "Read at maximum energy — like hyping up a crowd.")
        XCTAssertEqual(EmotionScript.tips.count, 3)
    }
}
