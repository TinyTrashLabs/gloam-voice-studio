import XCTest
import EngineKit
@testable import StudioKit

final class VoiceLibraryTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveCreatesMetaAndRef() throws {
        let meta = try lib.save(name: "Cruz", refWav: Data([1, 2, 3]), refText: "hello")
        XCTAssertEqual(meta.slug, "cruz")
        XCTAssertEqual(meta.name, "Cruz")
        XCTAssertEqual(meta.refText, "hello")
        // createdAt is UTC ISO-8601 with trailing Z (Python strftime parity)
        XCTAssertTrue(meta.createdAt.hasSuffix("Z"))
        XCTAssertEqual(meta.createdAt.count, 20)
        let saved = try Data(contentsOf: dir.appendingPathComponent("cruz/ref.wav"))
        XCTAssertEqual(saved, Data([1, 2, 3]))
    }

    func testSaveDuplicateSlugThrows() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        XCTAssertThrowsError(try lib.save(name: "CRUZ", refWav: Data([1]), refText: "")) {
            XCTAssertEqual($0 as? StudioError, .voiceExists(slug: "cruz"))
        }
    }

    func testGetReturnsMetaAndRefURL() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([7]), refText: "t")
        let (meta, refURL) = try lib.get("cruz")
        XCTAssertEqual(meta.slug, "cruz")
        XCTAssertEqual(try Data(contentsOf: refURL), Data([7]))
    }

    func testGetUnknownThrows() {
        XCTAssertThrowsError(try lib.get("nope")) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }

    func testListSortsByLowercasedNameAndSkipsCorrupt() throws {
        _ = try lib.save(name: "zeta", refWav: Data([1]), refText: "")
        _ = try lib.save(name: "Alpha", refWav: Data([1]), refText: "")
        // corrupt entry must be skipped, not crash the listing
        let bad = dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bad.appendingPathComponent("meta.json"))
        let names = lib.list().map(\.name)
        XCTAssertEqual(names, ["Alpha", "zeta"])
    }

    func testListEmptyWhenDirectoryMissing() {
        XCTAssertEqual(lib.list().count, 0)
    }

    func testDeleteRemovesVoice() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        try lib.delete("cruz")
        XCTAssertThrowsError(try lib.get("cruz"))
    }

    func testDeleteUnknownThrows() {
        XCTAssertThrowsError(try lib.delete("nope")) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }

    // MARK: variant resolution

    func testResolveNeutralAndNilReturnBase() throws {
        _ = try lib.save(name: "cruz", refWav: Data([1]), refText: "")
        _ = try lib.save(name: "cruz-hype", refWav: Data([2]), refText: "")
        XCTAssertEqual(try lib.resolve("cruz", emotion: nil).meta.slug, "cruz")
        XCTAssertEqual(try lib.resolve("cruz", emotion: .neutral).meta.slug, "cruz")
    }

    func testResolvePrefersEmotionVariant() throws {
        _ = try lib.save(name: "cruz", refWav: Data([1]), refText: "")
        _ = try lib.save(name: "cruz-hype", refWav: Data([2]), refText: "")
        XCTAssertEqual(try lib.resolve("cruz", emotion: .hype).meta.slug, "cruz-hype")
    }

    func testResolveAliasesHypeAndExcited() throws {
        _ = try lib.save(name: "cruz", refWav: Data([1]), refText: "")
        _ = try lib.save(name: "cruz-hype", refWav: Data([2]), refText: "")
        // no cruz-excited: excited falls through its alias chain to cruz-hype
        XCTAssertEqual(try lib.resolve("cruz", emotion: .excited).meta.slug, "cruz-hype")
    }

    func testResolveUnknownVariantFallsBackToBase() throws {
        _ = try lib.save(name: "cruz", refWav: Data([1]), refText: "")
        XCTAssertEqual(try lib.resolve("cruz", emotion: .warm).meta.slug, "cruz")
    }

    func testResolveUnknownBaseThrows() {
        XCTAssertThrowsError(try lib.resolve("nope", emotion: .hype)) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }

    // MARK: update

    func testUpdateRefTextOnly() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "old")
        let meta = try lib.update("cruz", refText: "new")
        XCTAssertEqual(meta.refText, "new")
        XCTAssertEqual(try lib.get("cruz").meta.refText, "new")
    }

    func testUpdateRefWavReplacesFile() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        _ = try lib.update("cruz", refWav: Data([9, 9]))
        XCTAssertEqual(try Data(contentsOf: try lib.get("cruz").refURL), Data([9, 9]))
    }

    func testUpdateRenameReslugsAndMovesDirectory() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([5]), refText: "t")
        let meta = try lib.update("cruz", name: "Night Cruz")
        XCTAssertEqual(meta.slug, "night-cruz")
        XCTAssertEqual(meta.name, "Night Cruz")
        XCTAssertEqual(try Data(contentsOf: try lib.get("night-cruz").refURL), Data([5]))
        XCTAssertThrowsError(try lib.get("cruz"))
    }

    func testUpdateRenameCollisionThrows() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        _ = try lib.save(name: "Vega", refWav: Data([1]), refText: "")
        XCTAssertThrowsError(try lib.update("cruz", name: "Vega")) {
            XCTAssertEqual($0 as? StudioError, .voiceExists(slug: "vega"))
        }
    }

    func testUpdateUnknownSlugThrows() {
        XCTAssertThrowsError(try lib.update("nope", refText: "x")) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }
}
