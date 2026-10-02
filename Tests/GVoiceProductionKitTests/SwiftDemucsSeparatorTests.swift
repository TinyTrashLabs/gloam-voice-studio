import XCTest
@testable import GVoiceProductionKit

final class SwiftDemucsSeparatorTests: XCTestCase {
    func testRejectsMissingWeightsAndNonStereoBeforeInference() async {
        let missing = URL(fileURLWithPath: "/tmp/no-such-demucs-weights-(UUID().uuidString)")
        do {
            _ = try await SwiftDemucsSeparator(weightsDirectory: missing)
            XCTFail("expected missing weights")
        } catch { }

        let fake = SwiftDemucsSeparator.testing { input in input }
        do {
            _ = try await fake.isolateVocals(.init(sampleRate: 44_100, channels: [[0, 1]]))
            XCTFail("expected stereo requirement")
        } catch let error as ReferencePreparationError {
            XCTAssertEqual(error, .stereoSourceRequired)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testPassesUntouchedStereoToNativeBackend() async throws {
        let input = ReferenceAudioBuffer(sampleRate: 44_100, channels: [[0, 0.25], [0.5, 1]])
        let separator = SwiftDemucsSeparator.testing { received in
            XCTAssertEqual(received, input)
            return received
        }
        XCTAssertEqual(separator.backendIdentifier, "swift-demucs-mlx")
        XCTAssertEqual(separator.modelIdentifier, "htdemucs_ft")
        let output = try await separator.isolateVocals(input)
        XCTAssertEqual(output, input)
    }
}
