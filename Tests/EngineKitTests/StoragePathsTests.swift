import XCTest
@testable import EngineKit

/// The store moved homes when the Gloam apps adopted a shared App Group. The
/// move is the dangerous part: it runs on every `models`/`voices` access, on
/// 41 GB of engines, in an app that can be quit mid-way.
final class StoragePathsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("storage-paths-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ name: String, children: [String]) throws -> URL {
        let dir = root.appendingPathComponent(name)
        for child in children {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(child), withIntermediateDirectories: true)
        }
        return dir
    }

    private func children(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// The fallback path. When the group container can't be resolved,
    /// `shared` IS `appSupport`, so migrate is asked to move a directory onto
    /// itself -- which must not empty it out.
    func testSamePathIsLeftAlone() throws {
        let store = try makeStore("Models", children: ["lux-tts", "kokoro"])
        StoragePaths.migrate(from: store, to: store)
        XCTAssertEqual(children(of: store), ["kokoro", "lux-tts"])
    }

    /// ...including when the two URLs differ only by spelling.
    func testUnstandardizedSamePathIsLeftAlone() throws {
        let store = try makeStore("Models", children: ["lux-tts"])
        let noisy = root.appendingPathComponent("./Models")
        StoragePaths.migrate(from: noisy, to: store)
        XCTAssertEqual(children(of: store), ["lux-tts"])
    }

    func testMovesChildrenAndRemovesEmptiedSource() throws {
        let old = try makeStore("Old", children: ["lux-tts", "kokoro"])
        let new = root.appendingPathComponent("New")
        StoragePaths.migrate(from: old, to: new)
        XCTAssertEqual(children(of: new), ["kokoro", "lux-tts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    /// An interrupted earlier run leaves some children already moved. The
    /// resident copy wins and the source copy is left in place -- never
    /// overwritten, never silently deleted.
    func testExistingDestinationChildIsNeverOverwritten() throws {
        let old = try makeStore("Old", children: ["lux-tts", "kokoro"])
        let new = try makeStore("New", children: ["lux-tts"])
        try "resident".write(to: new.appendingPathComponent("lux-tts/marker"),
                             atomically: true, encoding: .utf8)

        StoragePaths.migrate(from: old, to: new)

        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("lux-tts/marker"),
                                  encoding: .utf8), "resident")
        XCTAssertEqual(children(of: new), ["kokoro", "lux-tts"])
        // Source kept, because it still holds the copy we refused to move.
        XCTAssertEqual(children(of: old), ["lux-tts"])
    }

    func testMissingSourceIsNotAnError() {
        let new = root.appendingPathComponent("New")
        StoragePaths.migrate(from: root.appendingPathComponent("nope"), to: new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    /// macOS rejects a group id without the Team ID prefix; iOS's bare
    /// `group.` form does not provision here.
    func testAppGroupIsTeamPrefixed() {
        XCTAssertTrue(StoragePaths.appGroupID.hasPrefix("UT233385J9."),
                      "macOS App Group ids must begin with the Team ID")
    }
}
