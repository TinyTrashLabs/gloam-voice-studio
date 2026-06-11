import XCTest
@testable import StudioKit

final class HistoryStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeEntry(_ store: HistoryStore, text: String = "hi") throws -> HistoryEntry {
        try store.save(pcm: Data(repeating: 0, count: 48000), sampleRate: 24000,
                       text: text, backend: "chatterbox-turbo", voice: "cruz",
                       emotion: "neutral", wallMs: 420)
    }

    func testSaveWritesWavAndJson() throws {
        let store = HistoryStore(directory: dir)
        let entry = try makeEntry(store)
        XCTAssertTrue(entry.id.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#,
                                     options: .regularExpression) != nil)
        XCTAssertEqual(entry.sampleRate, 24000)
        XCTAssertEqual(entry.seconds, 1.0)   // 48000 bytes / 2 / 24000
        XCTAssertEqual(entry.wallMs, 420)
        let wav = try Data(contentsOf: dir.appendingPathComponent("\(entry.id).wav"))
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + 48000)
    }

    func testListNewestFirst() throws {
        let store = HistoryStore(directory: dir)
        let a = try makeEntry(store, text: "one")
        let b = try makeEntry(store, text: "two")
        let listed = store.list()
        XCTAssertEqual(listed.map(\.id), [b.id, a.id].sorted(by: >))
    }

    func testListEmptyWhenDirectoryMissing() {
        XCTAssertEqual(HistoryStore(directory: dir).list().count, 0)
    }

    func testWavURLRejectsUnsafeIds() {
        let store = HistoryStore(directory: dir)
        XCTAssertThrowsError(try store.wavURL("../../etc/passwd"))
        XCTAssertThrowsError(try store.wavURL("20260611-120000-zzzz"))
    }

    func testDeleteRemovesBothFiles() throws {
        let store = HistoryStore(directory: dir)
        let entry = try makeEntry(store)
        try store.delete(entry.id)
        XCTAssertEqual(store.list().count, 0)
        XCTAssertThrowsError(try store.wavURL(entry.id))
        XCTAssertThrowsError(try store.delete(entry.id))  // second delete: not found
    }

    func testClearReturnsRemovedCount() throws {
        let store = HistoryStore(directory: dir)
        _ = try makeEntry(store)
        _ = try makeEntry(store)
        XCTAssertEqual(try store.clear(), 2)
        XCTAssertEqual(store.list().count, 0)
        XCTAssertEqual(try store.clear(), 0)
    }

    func testPruneKeepsNewestCap() throws {
        let store = HistoryStore(directory: dir, cap: 3)
        var ids: [String] = []
        for i in 0..<5 { ids.append(try makeEntry(store, text: "\(i)").id) }
        let kept = store.list().map(\.id)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(Set(kept), Set(ids.suffix(3)))
        // pruned entries lost their wavs too
        XCTAssertThrowsError(try store.wavURL(ids[0]))
    }
}
