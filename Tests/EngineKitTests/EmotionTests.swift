import XCTest
@testable import EngineKit

final class EmotionTests: XCTestCase {
    func testCasesAndRawValuesMatchPythonEngine() {
        XCTAssertEqual(Emotion.allCases.map(\.rawValue),
                       ["flat", "neutral", "warm", "excited", "hype"])
    }

    func testChatterboxExaggerationTable() {
        XCTAssertEqual(Emotion.flat.chatterboxExaggeration, 0.2)
        XCTAssertEqual(Emotion.neutral.chatterboxExaggeration, 0.5)
        XCTAssertEqual(Emotion.warm.chatterboxExaggeration, 0.6)
        XCTAssertEqual(Emotion.excited.chatterboxExaggeration, 0.85)
        XCTAssertEqual(Emotion.hype.chatterboxExaggeration, 1.0)
    }

    func testFishTemperatureTable() {
        XCTAssertEqual(Emotion.flat.fishTemperature, 0.6)
        XCTAssertEqual(Emotion.neutral.fishTemperature, 0.7)
        XCTAssertEqual(Emotion.warm.fishTemperature, 0.8)
        XCTAssertEqual(Emotion.excited.fishTemperature, 0.9)
        XCTAssertEqual(Emotion.hype.fishTemperature, 1.0)
    }
}
