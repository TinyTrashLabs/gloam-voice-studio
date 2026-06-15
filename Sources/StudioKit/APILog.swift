import Foundation

public struct APILogEntry: Identifiable, Sendable {
    public let id = UUID()
    public var timestamp = Date()
    public var method: String
    public var path: String
    public var status: Int
    public var model: String?
    public var voice: String?
    public var instruct: String?
    public var durationMs: Int?
    public var note: String?

    public init(method: String, path: String, status: Int, model: String? = nil,
                voice: String? = nil, instruct: String? = nil, durationMs: Int? = nil,
                note: String? = nil) {
        self.method = method; self.path = path; self.status = status
        self.model = model; self.voice = voice; self.instruct = instruct
        self.durationMs = durationMs; self.note = note
    }
}

/// Observable ring buffer of API request records, newest-first. Written from the
/// server (off-main) via `record`, read by SwiftUI on the main actor.
@MainActor @Observable
public final class APILog {
    public private(set) var entries: [APILogEntry] = []
    private let capacity: Int

    public nonisolated init(capacity: Int = 500) { self.capacity = capacity }

    public func append(_ entry: APILogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    public func clear() { entries.removeAll() }

    /// Safe to call from any isolation (e.g. a Hummingbird handler); hops to main.
    public nonisolated func record(_ entry: APILogEntry) {
        Task { @MainActor in self.append(entry) }
    }
}
