import Foundation

/// Per-reply generation stats shown in the chat inspector.
public struct ChatMessageStats: Codable, Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var tokensPerSecond: Double?
    public var wallSeconds: Double?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil,
                tokensPerSecond: Double? = nil, wallSeconds: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.wallSeconds = wallSeconds
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: String            // "user" | "assistant"
    public var text: String
    public var createdAt: String       // UTC "yyyy-MM-dd'T'HH:mm:ss'Z'"
    public var stats: ChatMessageStats?
    /// true when the stream failed mid-reply; the partial text is kept.
    public var errored: Bool?
    /// Local file paths of attached images (vision input). Optional so old
    /// conversation files decode unchanged.
    public var attachments: [String]?
    public init(id: String, role: String, text: String, createdAt: String,
                stats: ChatMessageStats? = nil, errored: Bool? = nil,
                attachments: [String]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.stats = stats
        self.errored = errored
        self.attachments = attachments
    }
}

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var voiceSlug: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var messages: [ChatMessage]

    public init(id: String, voiceSlug: String, title: String,
                createdAt: String, updatedAt: String, messages: [ChatMessage]) {
        self.id = id
        self.voiceSlug = voiceSlug
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    public static func new(voiceSlug: String) -> Conversation {
        let now = ChatStore.timestamp()
        return Conversation(id: UUID().uuidString, voiceSlug: voiceSlug,
                            title: "New Chat", createdAt: now, updatedAt: now,
                            messages: [])
    }

    /// First user message → list title. Trimmed; capped at 48 chars + ellipsis.
    public static func deriveTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New Chat" }
        guard trimmed.count > 48 else { return trimmed }
        return String(trimmed.prefix(48)) + "…"
    }
}

/// Conversation persistence: one <uuid>.json per conversation under an
/// injectable directory (Application Support/Chats in the app, temp in tests).
/// Reply audio is deliberately NOT stored — replay re-synthesizes.
public final class ChatStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ conversation: Conversation) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(conversation)
            .write(to: directory.appendingPathComponent("\(conversation.id).json"),
                   options: .atomic)
    }

    public func list() -> [Conversation] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var conversations: [Conversation] = []
        for url in children where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let convo = try? JSONDecoder().decode(Conversation.self, from: data)
            else { continue }
            conversations.append(convo)
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func list(voiceSlug: String) -> [Conversation] {
        list().filter { $0.voiceSlug == voiceSlug }
    }

    public func load(_ id: String) -> Conversation? {
        guard isSafe(id),
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json"))
        else { return nil }
        return try? JSONDecoder().decode(Conversation.self, from: data)
    }

    public func delete(_ id: String) throws {
        guard isSafe(id) else { throw StudioError.historyEntryNotFound(id) }
        let url = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError.historyEntryNotFound(id)
        }
        // User deletions are recoverable: prefer the Trash (HistoryStore parity).
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch { try FileManager.default.removeItem(at: url) }
    }

    /// IDs are UUID strings we mint — reject anything else before touching paths.
    private func isSafe(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// "%Y-%m-%dT%H:%M:%SZ" in UTC — sorts lexically, matches VoiceLibrary.
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
