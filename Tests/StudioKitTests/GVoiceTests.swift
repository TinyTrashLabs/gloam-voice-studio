import XCTest
@testable import StudioKit

final class GVoiceTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gvoice-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testExportImportRoundTrip() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1, 2, 3, 4]), refText: "hello there")
        let pack = try GVoice.export("cruz", from: lib)
        try lib.delete("cruz")
        let meta = try GVoice.import(pack, into: lib)
        XCTAssertEqual(meta.name, "Cruz")
        XCTAssertEqual(meta.slug, "cruz")
        XCTAssertEqual(meta.refText, "hello there")
        XCTAssertEqual(try Data(contentsOf: try lib.get("cruz").refURL), Data([1, 2, 3, 4]))
    }

    func testExportUnknownSlugThrows() {
        XCTAssertThrowsError(try GVoice.export("nope", from: lib)) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }

    func testImportGarbageThrowsInvalidArchive() {
        XCTAssertThrowsError(try GVoice.import(Data([0xDE, 0xAD, 0xBE, 0xEF]), into: lib)) {
            guard case .invalidArchive = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
        }
    }

    func testImportMissingNameThrows() throws {
        // build a zip whose meta.json has no name
        let pack = try GVoice.makeArchive(entries: [
            ("meta.json", Data(#"{"refText":"x"}"#.utf8)),
            ("ref.wav", Data([1])),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            XCTAssertEqual($0 as? StudioError,
                           .invalidArchive("archive meta.json has no voice name"))
        }
    }

    func testImportCollisionThrowsVoiceExists() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        let pack = try GVoice.export("cruz", from: lib)
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            XCTAssertEqual($0 as? StudioError, .voiceExists(slug: "cruz"))
        }
    }
}
