import Foundation

/// One qwen3-design candidate's generation prompt + audio stats — metadata
/// only, the audio itself is a sibling .wav file. Mirrors `HistoryEntry` in
/// HistoryStore.swift.
public struct FoundryCandidateEntry: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: String
    public var description: String   // the qwen3-design instruct
    public var auditionLine: String
    public var language: String?
    public var sampleRate: Int
    public var seconds: Double
    public var wallSeconds: Double
}

/// Persistent qwen3-design candidate history, rooted at an injectable
/// directory. Newest `cap` entries are kept; older wav+json pairs are pruned
/// on save. File layout and id scheme mirror `HistoryStore`.
public final class FoundryCandidateStore: @unchecked Sendable {
    public let directory: URL
    /// Mutable (unlike HistoryStore's `let cap`): a Settings change should
    /// take effect on the very next save without re-constructing the store.
    public var cap: Int

    private let lock = NSLock()
    private var seq: UInt16 = 0
    private static let idPattern = #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#

    public init(directory: URL, cap: Int = 50) {
        self.directory = directory
        self.cap = cap
    }

    @discardableResult
    public func save(wav: Data, description: String, auditionLine: String, language: String?,
                     sampleRate: Int, seconds: Double, wallSeconds: Double) throws -> FoundryCandidateEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = newID()
        let entry = FoundryCandidateEntry(
            id: id, createdAt: Self.timestamp(), description: description,
            auditionLine: auditionLine, language: language, sampleRate: sampleRate,
            seconds: seconds, wallSeconds: wallSeconds)
        try wav.write(to: directory.appendingPathComponent("\(id).wav"))
        try JSONEncoder().encode(entry)
            .write(to: directory.appendingPathComponent("\(id).json"))
        prune()
        return entry
    }

    public func list() -> [FoundryCandidateEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var entries: [FoundryCandidateEntry] = []
        for url in children where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(FoundryCandidateEntry.self, from: data)
            else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.id > $1.id }
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
        try? FileManager.default.removeItem(at: json)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).wav"))
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
