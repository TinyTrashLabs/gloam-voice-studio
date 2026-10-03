import XCTest
@testable import GVoiceProductionKit

final class ReferenceCleanupModelTests: XCTestCase {
    func testStandardDefaultsDescribePackReadyReference() throws {
        let recipe = ReferenceCleanupRecipe.standard(segments: [.init(startSeconds: 1, endSeconds: 3)])
        XCTAssertEqual(recipe.highpassHz, 70)
        XCTAssertEqual(recipe.lowpassHz, 15_000)
        XCTAssertEqual(recipe.denoise, .light)
        XCTAssertEqual(recipe.fadeInSeconds, 0.05)
        XCTAssertEqual(recipe.fadeOutSeconds, 0.25)
        XCTAssertEqual(recipe.joinSilenceSeconds, 0.35)
        XCTAssertEqual(recipe.packSampleRate, 24_000)
        XCTAssertEqual(recipe.packChannels, 1)
        XCTAssertEqual(recipe.packPCMBitDepth, 16)
        XCTAssertNoThrow(try recipe.validated(sourceDuration: 4))
    }

    func testIsolationDefaultsFreezeValidatedDemucsRecipe() throws {
        let recipe = ReferenceCleanupRecipe.isolateVocals(segments: [.init(startSeconds: 0, endSeconds: 2)])
        XCTAssertEqual(recipe.denoise, .none)
        XCTAssertEqual(recipe.separation?.backend, "swift-demucs-mlx")
        XCTAssertEqual(recipe.separation?.model, "htdemucs_ft")
        XCTAssertEqual(recipe.separation?.shifts, 1)
        XCTAssertEqual(recipe.separation?.overlap, 0.5)
        XCTAssertNoThrow(try recipe.validated(sourceDuration: 2))
    }

    func testInvalidSegmentsAndStrongIsolationAreRejected() {
        let invalid: [ReferenceSegment] = [
            .init(startSeconds: .nan, endSeconds: 1),
            .init(startSeconds: 0, endSeconds: .infinity),
            .init(startSeconds: -1, endSeconds: 1),
            .init(startSeconds: 2, endSeconds: 1),
            .init(startSeconds: 0, endSeconds: 9),
        ]
        for segment in invalid {
            XCTAssertThrowsError(try ReferenceCleanupRecipe.standard(segments: [segment]).validated(sourceDuration: 3))
        }
        var overlap = ReferenceCleanupRecipe.standard(segments: [.init(startSeconds: 0, endSeconds: 2), .init(startSeconds: 1, endSeconds: 3)])
        XCTAssertThrowsError(try overlap.validated(sourceDuration: 3))
        var isolation = ReferenceCleanupRecipe.isolateVocals(segments: [.init(startSeconds: 0, endSeconds: 1)])
        isolation.denoise = .strong
        XCTAssertThrowsError(try isolation.validated(sourceDuration: 1))
        overlap.segments = []
        XCTAssertThrowsError(try overlap.validated(sourceDuration: 3))
    }
}
