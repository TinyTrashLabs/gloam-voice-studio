import Foundation

/// A word and when it is spoken, as the dialogue engine reported it.
public struct ScriptWordTiming: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

/// One generated take inside a script line.
///
/// `voices`, `words` and `note` are the dialogue path's additions and stay
/// optional: a session written by an older build decodes unchanged.
public struct ScriptTake: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: String
    public var sampleRate: Int
    public var seconds: Double
    public var wallSeconds: Double
    /// Every voice heard in this take. A dialogue scene has two; a single
    /// line has none, because the line already names its own voice.
    public var voices: [String]?
    public var words: [ScriptWordTiming]?
    /// Why the take is not quite what was asked for — a dropped prefix, say.
    public var note: String?
}

/// One line (cue) of a script with optional per-line direction overrides.
public struct ScriptLine: Codable, Equatable, Sendable, Identifiable {
    /// What the line contributes to the export. `nil` decodes as `.speech`, so
    /// sessions written before pauses existed load unchanged.
    public enum Kind: Codable, Equatable, Sendable {
        case speech
        case pause(seconds: Double)
    }

    public var id: UUID
    public var kind: Kind?
    public var text: String
    public var voiceSlug: String?
    public var emotion: String?      // Emotion rawValue; nil = session default
    public var speed: Float?
    public var takes: [ScriptTake]
    public var starredTakeID: String?

    public init(id: UUID = UUID(), text: String = "", kind: Kind = .speech) {
        self.id = id
        self.kind = kind
        self.text = text
        self.takes = []
    }

    /// A pause has no text to speak; every other line does.
    public var pauseSeconds: Double? {
        if case .pause(let seconds)? = kind { return seconds }
        return nil
    }
}

/// The whole script session document.
public struct ScriptSession: Codable, Equatable, Sendable {
    public var lines: [ScriptLine]
    public init(lines: [ScriptLine] = []) { self.lines = lines }
}

/// Persists one current session: session.json + take WAVs in one directory.
/// Takes are never pruned automatically — the user deletes them.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var seq: UInt32 = 0

    public init(directory: URL) { self.directory = directory }

    private var sessionURL: URL { directory.appendingPathComponent("session.json") }

    public func load() -> ScriptSession {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(ScriptSession.self, from: data)
        else { return ScriptSession() }
        return session
    }

    public func save(_ session: ScriptSession) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: sessionURL)
    }

    public func saveTake(pcm: Data, sampleRate: Int, wallSeconds: Double,
                         voices: [String]? = nil,
                         words: [ScriptWordTiming]? = nil,
                         note: String? = nil) throws -> ScriptTake {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let n: UInt32 = lock.withLock { seq &+= 1; return seq }
        let id = "take-" + String(UUID().uuidString.lowercased().prefix(8))
            + String(format: "-%04x", n)
        let seconds = sampleRate > 0
            ? Double(pcm.count) / 2 / Double(sampleRate) : 0
        let take = ScriptTake(id: id, createdAt: HistoryStore.timestamp(),
                              sampleRate: sampleRate, seconds: seconds,
                              wallSeconds: wallSeconds, voices: voices,
                              words: words, note: note)
        try WAVEncoder.encode(pcm16: pcm, sampleRate: sampleRate)
            .write(to: directory.appendingPathComponent("\(take.id).wav"))
        return take
    }

    public func takeWavURL(_ id: String) throws -> URL {
        guard isSafe(id) else { throw StudioError.historyEntryNotFound(id) }
        let url = directory.appendingPathComponent("\(id).wav")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError.historyEntryNotFound(id)
        }
        return url
    }

    /// The take's raw PCM16 (strips the 44-byte canonical header we wrote).
    public func takePCM(_ id: String) throws -> Data {
        Data(try Data(contentsOf: takeWavURL(id)).dropFirst(44))
    }

    public func deleteTake(_ id: String) {
        guard isSafe(id) else { return }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).wav"))
    }

    private func isSafe(_ id: String) -> Bool {
        id.hasPrefix("take-") && id.rangeOfCharacter(
            from: CharacterSet(charactersIn: "/\\.")) == nil
    }
}
