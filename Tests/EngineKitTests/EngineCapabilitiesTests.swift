import XCTest
@testable import EngineKit

final class EngineCapabilitiesTests: XCTestCase {

    // MARK: isModelDownloaded

    func testIsModelDownloadedTrueWhenConfigAndSafetensorsPresent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let modelDir = tmp.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data().write(to: modelDir.appendingPathComponent("config.json"))
        try Data().write(to: modelDir.appendingPathComponent("model.safetensors"))

        XCTAssertTrue(isModelDownloaded(folder: "m", in: tmp))
    }

    func testIsModelDownloadedFalseWhenOnlyConfigPresent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let modelDir = tmp.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data().write(to: modelDir.appendingPathComponent("config.json"))

        XCTAssertFalse(isModelDownloaded(folder: "m", in: tmp))
    }

    func testIsModelDownloadedFalseWhenFolderMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertFalse(isModelDownloaded(folder: "m", in: tmp))
    }

    // MARK: EngineCapabilities.current

    func testCurrentPhysicalMemoryIsPositive() {
        let caps = EngineCapabilities.current(
            modelsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        XCTAssertGreaterThan(caps.physicalMemoryBytes, 0)
    }

    func testCurrentFreeDiskBytesIsNonNegative() {
        let caps = EngineCapabilities.current(
            modelsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        XCTAssertGreaterThanOrEqual(caps.freeDiskBytes, 0)
    }

    func testCurrentIsAppleSiliconMatchesCompileTimeArch() {
        let caps = EngineCapabilities.current(
            modelsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        #if arch(arm64)
        XCTAssertTrue(caps.isAppleSilicon)
        #else
        XCTAssertFalse(caps.isAppleSilicon)
        #endif
    }

    func testCurrentDoesNotThrowWhenModelsRootDoesNotExist() {
        let nonExistent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deeply/nested/does/not/exist")
        // Must not crash or throw — just return a value
        let caps = EngineCapabilities.current(modelsRoot: nonExistent)
        XCTAssertGreaterThanOrEqual(caps.freeDiskBytes, 0)
    }

    func testCapabilitiesEquatable() {
        let a = EngineCapabilities(isAppleSilicon: true, physicalMemoryBytes: 16_000_000_000, freeDiskBytes: 50_000_000_000)
        let b = EngineCapabilities(isAppleSilicon: true, physicalMemoryBytes: 16_000_000_000, freeDiskBytes: 50_000_000_000)
        XCTAssertEqual(a, b)
    }

    // MARK: StoragePaths.directorySize (relocated, public)

    func testDirectorySizeReturnsSumOfFileSizes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data1 = Data(repeating: 0xAB, count: 1024)
        let data2 = Data(repeating: 0xCD, count: 2048)
        try data1.write(to: tmp.appendingPathComponent("file1.bin"))
        try data2.write(to: tmp.appendingPathComponent("file2.bin"))

        let size = StoragePaths.directorySize(tmp)
        XCTAssertEqual(size, 1024 + 2048)
    }

    func testDirectorySizeReturnsZeroForMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(StoragePaths.directorySize(missing), 0)
    }
}
