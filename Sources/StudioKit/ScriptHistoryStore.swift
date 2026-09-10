import Foundation

/// A generated script, kept so the work that made it is not thrown away.
///
/// Deliberately records where it CAME FROM as well as what it says. A script
/// on its own is a wall of dialogue with no way to tell which article it
/// summarised — and the article is the thing you check when a line sounds
/// wrong.
public struct ScriptHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public struct Turn: Codable, Equatable, Sendable {
        public var speaker: Int
        public var text: String
        public init(speaker: Int, text: String) { self.speaker = speaker; self.text = text }
    }

    /// How the article got here: "link", "topic" or "text".
    public var sourceKind: String
    public var id: String
    public var createdAt: String
    public var title: String
    public var url: String?
    public var siteName: String?
    public var byline: String?
    /// Words in the article the script was written from — the number that says
    /// whether a thin script came from a thin source.
    public var articleWords: Int
    public var targetMinutes: Double
    /// Which chat model wrote it. Script quality is mostly this.
    public var model: String
    public var turns: [Turn]

    public init(id: String, createdAt: String, sourceKind: String, title: String,
                url: String? = nil, siteName: String? = nil, byline: String? = nil,
                articleWords: Int, targetMinutes: Double, model: String, turns: [Turn]) {
        self.id = id; self.createdAt = createdAt; self.sourceKind = sourceKind
        self.title = title; self.url = url; self.siteName = siteName; self.byline = byline
        self.articleWords = articleWords; self.targetMinutes = targetMinutes
        self.model = model; self.turns = turns
    }

    public var wordCount: Int {
        turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// One line naming the source, for a list row.
    public var sourceLabel: String {
        if let siteName, !siteName.isEmpty { return siteName }
        if let url, let host = URL(string: url)?.host() { return host }
        return sourceKind == "text" ? "Pasted text" : "Unknown source"
    }
}

/// Saved scripts, newest first, capped.
///
/// Separate from `HistoryStore`, which stores rendered audio. A script is worth
/// keeping BEFORE any audio exists — it costs a whole LLM run to make, and
/// until now it was discarded the moment the review sheet closed.
public final class ScriptHistoryStore: @unchecked Sendable {
    public let directory: URL
    public let cap: Int

    private let lock = NSLock()
    private var seq: UInt16 = 0
    private static let idPattern = #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#

    public init(directory: URL, cap: Int = 100) {
        self.directory = directory
        self.cap = cap
    }

    @discardableResult
    public func save(_ entry: ScriptHistoryEntry) throws -> ScriptHistoryEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored = entry
        if stored.id.isEmpty { stored.id = newID() }
        try JSONEncoder().encode(stored)
            .write(to: directory.appendingPathComponent("\(stored.id).json"))
        prune()
        return stored
    }

    /// Build and save in one step, so callers never have to invent an id or a
    /// timestamp (and never disagree about their format).
    @discardableResult
    public func record(sourceKind: String, title: String, url: String?, siteName: String?,
                       byline: String?, articleWords: Int, targetMinutes: Double,
                       model: String, turns: [ScriptHistoryEntry.Turn]) throws
        -> ScriptHistoryEntry
    {
        try save(ScriptHistoryEntry(
            id: newID(), createdAt: Self.timestamp(), sourceKind: sourceKind, title: title,
            url: url, siteName: siteName, byline: byline, articleWords: articleWords,
            targetMinutes: targetMinutes, model: model, turns: turns))
    }

    public func list() -> [ScriptHistoryEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var entries: [ScriptHistoryEntry] = []
        for url in children where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(ScriptHistoryEntry.self, from: data)
            else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.id > $1.id }
    }

    public func delete(_ id: String) throws {
        guard isSafe(id) else { throw StudioError.historyEntryNotFound(id) }
        let json = directory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: json.path) else {
            throw StudioError.historyEntryNotFound(id)
        }
        // Recoverable, like HistoryStore's deletions: the Trash where there is
        // one, permanent removal only where there isn't.
        do { try FileManager.default.trashItem(at: json, resultingItemURL: nil) }
        catch { try? FileManager.default.removeItem(at: json) }
    }

    @discardableResult
    public func clear() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var removed = 0
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { try? FileManager.default.removeItem(at: url) }
            removed += 1
        }
        return removed
    }

    private func prune() {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let jsons = children.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard jsons.count > cap else { return }
        for url in jsons.prefix(jsons.count - cap) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isSafe(_ id: String) -> Bool {
        id.range(of: Self.idPattern, options: .regularExpression) != nil
    }

    /// Same id shape as `HistoryStore`, so both histories sort and prune the
    /// same way and an id is recognisable as one of ours.
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

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
