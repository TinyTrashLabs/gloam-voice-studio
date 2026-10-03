import XCTest
@testable import GVoiceProductionKit

final class GVoicePrepareArgumentsTests: XCTestCase {
    func testParsesRepeatedSegmentsAndNativeIsolationOptions() throws {
        let options = try GVoicePrepareOptions.parse([
            "--input", "/tmp/source file.wav", "--output", "/tmp/prepared",
            "--segment", "1.25:2.5", "--segment", "3:4",
            "--mode", "isolate-vocals", "--denoise", "none",
            "--transcript-file", "/tmp/ref.txt", "--weights", "/tmp/weights",
            "--source-identity", "owned interview"
        ])
        XCTAssertEqual(options.input.path, "/tmp/source file.wav")
        XCTAssertEqual(options.recipe.mode, .isolateVocals)
        XCTAssertEqual(options.recipe.segments.count, 2)
        XCTAssertEqual(options.weights?.path, "/tmp/weights")
    }

    func testRejectsMissingValuesAndStrongIsolation() {
        XCTAssertThrowsError(try GVoicePrepareOptions.parse(["--input"]))
        XCTAssertThrowsError(try GVoicePrepareOptions.parse([
            "--input", "a", "--output", "b", "--segment", "0:1",
            "--mode", "isolate-vocals", "--denoise", "strong", "--transcript-file", "t"
        ]))
    }
}
