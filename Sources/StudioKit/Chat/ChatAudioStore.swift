import Foundation

/// One saved chat-reply take's metadata — audio itself is a sibling .wav
/// file. Mirrors `FoundryCandidateEntry`/`HistoryEntry`.
public struct ChatAudioEntry: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: String
    public var conversationID: String
    public var messageID: String
    public var backend: String       // which TTS engine produced this take
    public var sampleRate: Int
    public var seconds: Double
    public var wallMs: Int?
}

/// Persistent chat-reply audio, rooted at an injectable directory. Newest
/// `cap` entries are kept globally (not per-conversation); older wav+json
/// pairs are pruned on save. File layout and id scheme mirror `HistoryStore`
/// and `FoundryCandidateStore`. `conversationID`/`messageID` aren't needed
/// for playback (the owning `ChatMessage` references its own take ids
/// directly) — they exist so a conversation delete can cascade-delete its
/// takes without reverse-scanning every conversation's message list.
public final class ChatAudioStore: @unchecked Sendable {
    public let directory: URL
    /// Mutable (unlike a `let`): a Settings change should take effect on the
    /// very next save without re-constructing the store.
    public var cap: Int

    private let lock = NSLock()
    private var seq: UInt16 = 0
    private static let idPattern = #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#

    public init(directory: URL, cap: Int = 200) {
        self.directory = directory
        self.cap = cap
    }

    @discardableResult
    public func save(wav: Data, conversationID: String, messageID: String, backend: String,
                     sampleRate: Int, seconds: Double, wallMs: Int?) throws -> ChatAudioEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = newID()
        let entry = ChatAudioEntry(
            id: id, createdAt: Self.timestamp(), conversationID: conversationID,
            messageID: messageID, backend: backend, sampleRate: sampleRate,
            seconds: seconds, wallMs: wallMs)
        try wav.write(to: directory.appendingPathComponent("\(id).wav"))
        try JSONEncoder().encode(entry)
            .write(to: directory.appendingPathComponent("\(id).json"))
        prune()
        return entry
    }

    public func list() -> [ChatAudioEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var entries: [ChatAudioEntry] = []
        for url in children where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(ChatAudioEntry.self, from: data)
            else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.id > $1.id }
    }

    public func list(conversationID: String) -> [ChatAudioEntry] {
        list().filter { $0.conversationID == conversationID }
    }

    public func entry(_ id: String) -> ChatAudioEntry? {
        guard isSafe(id),
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json"))
        else { return nil }
        return try? JSONDecoder().decode(ChatAudioEntry.self, from: data)
    }

    public func wavURL(_ id: String) throws -> URL {
        guard isSafe(id) else { throw StudioError.historyEntryNotFound(id) }
        let url = directory.appendingPathComponent("\(id).wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError.historyEntryNotFound(id)
        }
        return url
    }

    public func delete(_ id: String) throws {
        guard isSafe(id) else { throw StudioError.historyEntryNotFound(id) }
        let json = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: json.path) else {
            throw StudioError.historyEntryNotFound(id)
        }
        Self.discard(json)
        Self.discard(directory.appendingPathComponent("\(id).wav"))
    }

    /// Best-effort cascade delete for every take belonging to a conversation
    /// (called when the conversation itself is deleted) — never throws,
    /// since callers treat this as cleanup, not a user-facing operation.
    public func deleteAll(conversationID: String) {
        for entry in list(conversationID: conversationID) {
            try? delete(entry.id)
        }
    }

    /// User deletions are recoverable: prefer the Trash (HistoryStore parity).
    private static func discard(_ url: URL) {
        let fm = FileManager.default
        do { try fm.trashItem(at: url, resultingItemURL: nil) }
        catch { try? fm.removeItem(at: url) }
    }

    private func prune() {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let jsons = children.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard jsons.count > cap else { return }
        for url in jsons.prefix(jsons.count - cap) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.deletingPathExtension().appendingPathExtension("wav"))
        }
    }

    private func isSafe(_ id: String) -> Bool {
        id.range(of: Self.idPattern, options: .regularExpression) != nil
    }

    private func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let n: UInt16 = lock.withLock {
            seq = seq &+ 1
            if seq == 0xFFFF { seq = 0 }
            return seq
        }
        return f.string(from: Date()) + String(format: "-%04x", n)
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
