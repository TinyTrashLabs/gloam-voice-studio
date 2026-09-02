import XCTest
@testable import EngineKit

final class StreamingSynthesisTests: XCTestCase {
    /// A model that only implements the batch call still streams — one chunk.
    private final class BatchOnlyModel: SpeechModel, @unchecked Sendable {
        let sampleRate = 24000
        func synthesize(_ request: ProviderRequest) async throws -> [Float] {
            [0.1, 0.2, 0.3]
        }
    }

    func testBatchOnlyModelsGetAStreamForFree() async throws {
        let model = BatchOnlyModel()
        var collected: [Float] = []
        for try await chunk in model.synthesizeStream(ProviderRequest(text: "hi")) {
            collected.append(contentsOf: chunk)
        }
        XCTAssertEqual(collected, [0.1, 0.2, 0.3])
    }

    /// A streaming model's chunks arrive separately, not concatenated up front.
    private final class ChunkedModel: SpeechModel, @unchecked Sendable {
        let sampleRate = 24000
        func synthesize(_ request: ProviderRequest) async throws -> [Float] { [1, 2, 3, 4] }
        func synthesizeStream(_ request: ProviderRequest) -> AsyncThrowingStream<[Float], Error> {
            AsyncThrowingStream { continuation in
                continuation.yield([1, 2])
                continuation.yield([3, 4])
                continuation.finish()
            }
        }
    }

    func testStreamingModelYieldsMultipleChunks() async throws {
        var chunks: [[Float]] = []
        for try await chunk in ChunkedModel().synthesizeStream(ProviderRequest(text: "hi")) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, [[1, 2], [3, 4]])
    }
}
