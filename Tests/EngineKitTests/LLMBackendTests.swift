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

    func testMinRAMBytes() {
        XCTAssertEqual(LLMBackendID.qwen3_1_7b.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(LLMBackendID.gemma4_e2b.minRAMBytes, 8_000_000_000)
        XCTAssertEqual(LLMBackendID.qwen3_8b.minRAMBytes, 16_000_000_000)
        XCTAssertEqual(LLMBackendID.gemma4_e4b.minRAMBytes, 16_000_000_000)
        XCTAssertEqual(LLMBackendID.gemma4_26b.minRAMBytes, 32_000_000_000)
        XCTAssertEqual(LLMBackendID.gemma4_31b.minRAMBytes, 64_000_000_000)
    }

    func testMinRAMBytesPositive() {
        for id in LLMBackendID.allCases {
            XCTAssertGreaterThan(id.minRAMBytes, 0, "\(id) must declare a RAM floor")
        }
    }
}
