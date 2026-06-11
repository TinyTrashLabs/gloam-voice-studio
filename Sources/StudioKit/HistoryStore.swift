import Foundation

/// One generation's metadata. Field names/values match the Python engine's
/// history entries so exported JSON is interchangeable.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: String
    public var sampleRate: Int
    public var seconds: Double
    public var text: String?
    public var backend: String?
    public var voice: String?
    public var emotion: String?
    public var wallMs: Int?
}

/// Persistent generation history rooted at an injectable directory. Newest
/// CAP entries are kept; older wav+json pairs are pruned on save.
public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    public let cap: Int

    private let lock = NSLock()   // guards seq only; file state lives on disk
    private var seq: UInt16 = 0
    private static let idPattern = #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#

    public init(directory: URL, cap: Int = 200) {
        self.directory = directory
        self.cap = cap
    }

    public func save(pcm: Data, sampleRate: Int, text: String?, backend: String?,
                     voice: String?, emotion: String?, wallMs: Int?) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = newID()
        let seconds = sampleRate > 0
            ? (Double(pcm.count) / 2 / Double(sampleRate) * 100).rounded() / 100
            : 0
        let entry = HistoryEntry(id: id, createdAt: Self.timestamp(),
                                 sampleRate: sampleRate, seconds: seconds,
                                 text: text, backend: backend, voice: voice,
                                 emotion: emotion, wallMs: wallMs)
        try WAVEncoder.encode(pcm16: pcm, sampleRate: sampleRate)
            .write(to: directory.appendingPathComponent("\(id).wav"))
        try JSONEncoder().encode(entry)
            .write(to: directory.appendingPathComponent("\(id).json"))
        prune()
        return entry
    }

    public func list() -> [HistoryEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var entries: [HistoryEntry] = []
        for url in children where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(HistoryEntry.self, from: data)
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
        try FileManager.default.removeItem(at: json)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).wav"))
    }

    @discardableResult
    public func clear() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var removed = 0
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for url in children where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.deletingPathExtension().appendingPathExtension("wav"))
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

    /// "%Y-%m-%dT%H:%M:%S" in local time, no Z — history.py parity.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
