import XCTest
@testable import StudioKit

final class ChatAudioStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chataudio-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeEntry(_ store: ChatAudioStore, conversationID: String = "convo-1",
                   messageID: String = "msg-1", backend: String = "chatterbox-turbo"
                  ) throws -> ChatAudioEntry {
        try store.save(wav: Data(repeating: 0, count: 100), conversationID: conversationID,
                       messageID: messageID, backend: backend, sampleRate: 24000,
                       seconds: 1.5, wallMs: 300)
    }

    func testSaveWritesWavAndJson() throws {
        let store = ChatAudioStore(directory: dir)
        let entry = try makeEntry(store)
        XCTAssertTrue(entry.id.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#,
                                     options: .regularExpression) != nil)
        XCTAssertEqual(entry.conversationID, "convo-1")
        XCTAssertEqual(entry.messageID, "msg-1")
        XCTAssertEqual(entry.backend, "chatterbox-turbo")
        let wav = try Data(contentsOf: dir.appendingPathComponent("\(entry.id).wav"))
        XCTAssertEqual(wav.count, 100)
    }

    func testListNewestFirst() throws {
        let store = ChatAudioStore(directory: dir)
        let a = try makeEntry(store, messageID: "one")
        let b = try makeEntry(store, messageID: "two")
        XCTAssertEqual(store.list().map(\.id), [b.id, a.id].sorted(by: >))
    }

    func testListEmptyWhenDirectoryMissing() {
        XCTAssertEqual(ChatAudioStore(directory: dir).list().count, 0)
    }

    func testListByConversationIDFilters() throws {
        let store = ChatAudioStore(directory: dir)
        let a = try makeEntry(store, conversationID: "convo-a")
        _ = try makeEntry(store, conversationID: "convo-b")
        XCTAssertEqual(store.list(conversationID: "convo-a").map(\.id), [a.id])
    }

    func testEntryLooksUpByID() throws {
        let store = ChatAudioStore(directory: dir)
        let entry = try makeEntry(store)
        XCTAssertEqual(store.entry(entry.id), entry)
        XCTAssertNil(store.entry("not-an-id"))
    }

    func testWavURLRejectsUnsafeIds() {
        let store = ChatAudioStore(directory: dir)
        XCTAssertThrowsError(try store.wavURL("../../etc/passwd"))
        XCTAssertThrowsError(try store.wavURL("20260611-120000-zzzz"))
    }

    func testDeleteRemovesBothFiles() throws {
        let store = ChatAudioStore(directory: dir)
        let entry = try makeEntry(store)
        try store.delete(entry.id)
        XCTAssertEqual(store.list().count, 0)
        XCTAssertThrowsError(try store.wavURL(entry.id))
        XCTAssertThrowsError(try store.delete(entry.id))
    }

    func testDeleteAllRemovesOnlyMatchingConversation() throws {
        let store = ChatAudioStore(directory: dir)
        let a = try makeEntry(store, conversationID: "convo-a")
        let b = try makeEntry(store, conversationID: "convo-b")
        store.deleteAll(conversationID: "convo-a")
        XCTAssertEqual(store.list().map(\.id), [b.id])
        XCTAssertThrowsError(try store.wavURL(a.id))
    }

    func testPruneKeepsNewestCap() throws {
        let store = ChatAudioStore(directory: dir, cap: 3)
        var ids: [String] = []
        for i in 0..<5 { ids.append(try makeEntry(store, messageID: "\(i)").id) }
        let kept = store.list().map(\.id)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(Set(kept), Set(ids.suffix(3)))
        XCTAssertThrowsError(try store.wavURL(ids[0]))
    }

    func testMutatingCapTakesEffectOnNextSave() throws {
        let store = ChatAudioStore(directory: dir, cap: 50)
        for i in 0..<5 { _ = try makeEntry(store, messageID: "\(i)") }
        store.cap = 2
        _ = try makeEntry(store, messageID: "six")
        XCTAssertEqual(store.list().count, 2)
    }
}
