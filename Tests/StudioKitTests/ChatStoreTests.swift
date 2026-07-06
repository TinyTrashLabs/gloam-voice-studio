import XCTest
@testable import StudioKit

final class ChatStoreTests: XCTestCase {
    var dir: URL!
    var store: ChatStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatstore-tests-\(UUID().uuidString)")
        store = ChatStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveLoadRoundtrip() throws {
        var convo = Conversation.new(voiceSlug: "willow")
        convo.title = "Test chat"
        convo.messages = [
            ChatMessage(id: UUID().uuidString, role: "user", text: "hi",
                        createdAt: ChatStore.timestamp()),
            ChatMessage(id: UUID().uuidString, role: "assistant", text: "hello!",
                        createdAt: ChatStore.timestamp(),
                        stats: ChatMessageStats(promptTokens: 12, completionTokens: 3,
                                                tokensPerSecond: 41.5, wallSeconds: 0.4)),
        ]
        try store.save(convo)
        let loaded = store.load(convo.id)
        XCTAssertEqual(loaded, convo)
        XCTAssertEqual(loaded?.messages[1].stats?.tokensPerSecond, 41.5)
    }

    func testListSortsByUpdatedAtDescending() throws {
        var a = Conversation.new(voiceSlug: "v"); a.updatedAt = "2026-07-01T00:00:00Z"
        var b = Conversation.new(voiceSlug: "v"); b.updatedAt = "2026-07-03T00:00:00Z"
        var c = Conversation.new(voiceSlug: "other"); c.updatedAt = "2026-07-02T00:00:00Z"
        try store.save(a); try store.save(b); try store.save(c)
        XCTAssertEqual(store.list().map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(store.list(voiceSlug: "v").map(\.id), [b.id, a.id])
    }

    func testDeleteRemovesConversation() throws {
        let convo = Conversation.new(voiceSlug: "v")
        try store.save(convo)
        try store.delete(convo.id)
        XCTAssertNil(store.load(convo.id))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testDeleteRejectsUnsafeIDs() {
        XCTAssertThrowsError(try store.delete("../../etc/passwd"))
    }

    func testDeriveTitleTruncates() {
        XCTAssertEqual(Conversation.deriveTitle(from: "  Hello there  "), "Hello there")
        let long = String(repeating: "word ", count: 30)
        let title = Conversation.deriveTitle(from: long)
        XCTAssertLessThanOrEqual(title.count, 49)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(Conversation.deriveTitle(from: "   "), "New Chat")
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(store.load(UUID().uuidString))
    }
}

extension ChatStoreTests {
    func testMigrateVoiceSlugRepointsOnlyMatchingConversations() throws {
        var a = Conversation.new(voiceSlug: "dj-nova")
        a.title = "A"
        var b = Conversation.new(voiceSlug: "dj-nova")
        b.title = "B"
        var c = Conversation.new(voiceSlug: "midge")
        c.title = "C"
        try store.save(a); try store.save(b); try store.save(c)

        let moved = store.migrateVoiceSlug(from: "dj-nova", to: "roomba")

        XCTAssertEqual(moved, 2)
        XCTAssertEqual(store.list(voiceSlug: "roomba").map(\.title).sorted(), ["A", "B"])
        XCTAssertTrue(store.list(voiceSlug: "dj-nova").isEmpty)
        XCTAssertEqual(store.list(voiceSlug: "midge").map(\.title), ["C"])
    }
}
