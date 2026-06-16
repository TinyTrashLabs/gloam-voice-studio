import XCTest
@testable import EngineKit

final class LLMBackendTests: XCTestCase {
    func testRepoIdsResolve() {
        XCTAssertEqual(LLMBackendID.qwen3_1_7b.repoId, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(LLMBackendID.gemma4_e4b.repoId, "mlx-community/gemma-4-e4b-it-4bit")
    }

    func testFamilyClassification() {
        XCTAssertEqual(LLMBackendID.qwen3_1_7b.family, .qwen)
        XCTAssertEqual(LLMBackendID.gemma4_e4b.family, .gemma)
    }

    func testApproxBytesPositive() {
        for id in LLMBackendID.allCases {
            XCTAssertGreaterThan(id.approxBytes, 0, "\(id) must declare a size")
        }
    }

    func testDiskFolderUnique() {
        let folders = LLMBackendID.allCases.map(\.diskFolder)
        XCTAssertEqual(Set(folders).count, folders.count, "disk folders must be unique")
    }
}
