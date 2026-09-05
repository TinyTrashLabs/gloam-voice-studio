import XCTest
@testable import StudioKit

final class ScriptHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ScriptHistoryStore!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("script-history-\(UUID().uuidString)")
        store = ScriptHistoryStore(directory: dir, cap: 3)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ title: String, kind: String = "link") throws -> ScriptHistoryEntry {
        try store.record(sourceKind: kind, title: title,
                         url: "https://example.com/\(title)", siteName: "Example News",
                         byline: "A Reporter", articleWords: 900, targetMinutes: 5,
                         model: "gemma4-12b",
                         turns: [.init(speaker: 1, text: "Hello there."),
                                 .init(speaker: 2, text: "Hi.")])
    }

    /// The whole point: the article is recorded alongside the script, because
    /// a wall of dialogue with no source is unverifiable.
    func testTheSourceIsStoredWithTheScript() throws {
        let saved = try record("fusion")
        let read = try XCTUnwrap(store.list().first)
        XCTAssertEqual(read.id, saved.id)
        XCTAssertEqual(read.url, "https://example.com/fusion")
        XCTAssertEqual(read.siteName, "Example News")
        XCTAssertEqual(read.byline, "A Reporter")
        XCTAssertEqual(read.articleWords, 900)
        XCTAssertEqual(read.model, "gemma4-12b")
        XCTAssertEqual(read.turns.map(\.speaker), [1, 2])
    }

    func testNewestFirst() throws {
        _ = try record("one"); _ = try record("two"); _ = try record("three")
        XCTAssertEqual(store.list().map(\.title), ["three", "two", "one"])
    }

    func testTheCapPrunesOldestFirst() throws {
        for title in ["a", "b", "c", "d", "e"] { _ = try record(title) }
        XCTAssertEqual(store.list().map(\.title), ["e", "d", "c"])
    }

    func testDeleteRemovesOnlyThatEntry() throws {
        let first = try record("one")
        _ = try record("two")
        try store.delete(first.id)
        XCTAssertEqual(store.list().map(\.title), ["two"])
    }

    /// An id is used to build a path, so it must never be able to escape the
    /// history directory.
    func testATraversalIdIsRefusedRatherThanResolved() throws {
        _ = try record("one")
        XCTAssertThrowsError(try store.delete("../../etc/passwd"))
        XCTAssertEqual(store.list().count, 1)
    }

    func testMissingDirectoryListsEmptyRatherThanThrowing() {
        let empty = ScriptHistoryStore(
            directory: dir.appendingPathComponent("nope"))
        XCTAssertTrue(empty.list().isEmpty)
    }

    /// The row label has to say something useful for every source kind,
    /// including the one with no URL at all.
    func testPastedTextStillNamesItsSource() throws {
        let entry = ScriptHistoryEntry(
            id: "20260905-120000-0001", createdAt: "2026-09-05T12:00:00",
            sourceKind: "text", title: "Something I wrote", url: nil, siteName: nil,
            byline: nil, articleWords: 400, targetMinutes: 2, model: "gemma4-12b",
            turns: [.init(speaker: 1, text: "Hi.")])
        XCTAssertEqual(entry.sourceLabel, "Pasted text")
    }

    func testWordCountMeasuresTheScriptNotTheArticle() throws {
        let entry = try record("fusion")
        XCTAssertEqual(entry.wordCount, 3)   // "Hello there." + "Hi."
    }
}
