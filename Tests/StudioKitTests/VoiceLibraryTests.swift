import XCTest
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
}
