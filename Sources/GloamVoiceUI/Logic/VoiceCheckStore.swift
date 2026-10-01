import Foundation

/// The clone-time check's verdict per voice (`Qualification`), one JSON file
/// per slug under `Documents/voice-checks/`. Deliberately NOT in `VoiceMeta`
/// or the `.gvoice` pack: the verdict belongs to this phone and the engine it
/// rendered on, and means nothing on another device.
///
/// Read by Compose off the main actor; `load` never throws into the UI -- a
/// missing or unreadable file is simply "no stored check".
public enum VoiceCheckStore {
    public static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice-checks", isDirectory: true)
    }

    public static func url(slug: String, in dir: URL = directory) -> URL {
        dir.appendingPathComponent("\(slug).json")
    }

    public static func save(_ q: Qualification, slug: String) throws { try save(q, slug: slug, in: directory) }
    public static func load(slug: String) -> Qualification? { load(slug: slug, in: directory) }
    public static func delete(slug: String) { delete(slug: slug, in: directory) }

    public static func save(_ q: Qualification, slug: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(q).write(to: url(slug: slug, in: dir), options: .atomic)
    }

    public static func load(slug: String, in dir: URL) -> Qualification? {
        guard let data = try? Data(contentsOf: url(slug: slug, in: dir)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Qualification.self, from: data)
    }

    public static func delete(slug: String, in dir: URL) {
        try? FileManager.default.removeItem(at: url(slug: slug, in: dir))
    }

    /// A check describes the master it was made on. A master written after
    /// it (a new take, a cleanup, a rebuild) needs measuring again. ISO-8601
    /// drops sub-second precision, so a second's slack keeps a check saved
    /// right after its master from reading as older than it.
    public static func isCurrent(checkedAt: Date, masterModified: Date?) -> Bool {
        guard let masterModified else { return true }
        return masterModified.timeIntervalSince(checkedAt) < 1
    }

    /// Was the check made with these words? A sidecar from before the
    /// transcript was stored (nil) cannot say, so it is not.
    public static func sameTranscript(_ checked: String?, _ current: String) -> Bool {
        guard let checked else { return false }
        func norm(_ t: String) -> String { t.trimmingCharacters(in: .whitespacesAndNewlines) }
        return norm(checked) == norm(current)
    }

    /// What Compose shows for a flagged render of this voice: the stored
    /// findings when the check still describes the reference, nil when the
    /// reference must be measured again (no check, a newer reference, a
    /// changed transcript, or a message this build no longer writes).
    public static func storedAdvice(_ q: Qualification?, referenceModified: Date?,
                             transcript: String) -> [ReferenceAdvice.Finding]? {
        guard let q, isCurrent(checkedAt: q.checkedAt, masterModified: referenceModified),
              sameTranscript(q.transcript, transcript) else { return nil }
        let findings = q.findings.compactMap(ReferenceAdvice.Finding.init(storedMessage:))
        return findings.count == q.findings.count ? findings : nil
    }
}
