import EngineKit
import Foundation

/// Single source of truth for the Lab comparison shelf. `@MainActor @Observable`
/// so the Lab tab redraws when it mutates; because the embedded MCP/HTTP server
/// runs in-process, the tool handlers mutate this same instance (hopping to the
/// main actor), so an agent's `lab_put_clip` shows up live in the tab and a
/// mark pinned in the tab is visible to the next `lab_read_feedback` -- no file
/// watching, no second server.
///
/// The store owns its clips' bytes: every wav is copied into `clips/` on ingest
/// so a source file moving never breaks a saved comparison. `lab.json` is
/// rewritten atomically after each mutation.
@MainActor @Observable
public final class LabStore {
    /// The app-wide store, rooted at `StoragePaths.lab`.
    public static let shared = LabStore(directory: StoragePaths.lab)

    public private(set) var state: LabState
    private let directory: URL
    private var clipsDir: URL { directory.appendingPathComponent("clips") }
    private var jsonURL: URL { directory.appendingPathComponent("lab.json") }

    /// Inject a directory for tests; defaults to the shared app location.
    public init(directory: URL) {
        self.directory = directory
        self.state = LabStore.load(from: directory.appendingPathComponent("lab.json"))
    }

    // MARK: Groups

    /// Create a group, or update the heading/listenFor of an existing one.
    @discardableResult
    public func setGroup(id: String? = nil, heading: String,
                         listenFor: String = "") -> LabGroup {
        if let id, let idx = state.groups.firstIndex(where: { $0.id == id }) {
            state.groups[idx].heading = heading
            state.groups[idx].listenFor = listenFor
            state.groups[idx].updatedAt = Date()
            save()
            return state.groups[idx]
        }
        let group = LabGroup(id: id ?? UUID().uuidString, heading: heading,
                             listenFor: listenFor)
        state.groups.append(group)
        save()
        return group
    }

    /// Find a group by exact heading, creating it if absent -- lets an agent
    /// address a comparison by name without a prior round-trip.
    @discardableResult
    public func ensureGroup(heading: String, listenFor: String = "") -> LabGroup {
        if let existing = state.groups.first(where: { $0.heading == heading }) {
            return existing
        }
        return setGroup(heading: heading, listenFor: listenFor)
    }

    public func group(_ id: String) -> LabGroup? {
        state.groups.first { $0.id == id }
    }

    public func setVerdict(groupID: String, verdict: String?) {
        guard let idx = state.groups.firstIndex(where: { $0.id == groupID }) else { return }
        state.groups[idx].verdict = verdict
        state.groups[idx].updatedAt = Date()
        save()
    }

    public func deleteGroup(_ id: String) {
        for clip in state.clips where clip.groupID == id {
            try? FileManager.default.removeItem(at: clipsDir.appendingPathComponent(clip.file))
        }
        state.clips.removeAll { $0.groupID == id }
        state.groups.removeAll { $0.id == id }
        save()
    }

    // MARK: Requests (asks aimed at the agent)

    @discardableResult
    public func addRequest(groupID: String, text: String) -> LabRequest? {
        guard let idx = state.groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let req = LabRequest(text: text)
        state.groups[idx].requests.append(req)
        state.groups[idx].updatedAt = Date()
        save()
        return req
    }

    public func setRequestStatus(groupID: String, requestID: String,
                                 status: LabRequest.Status) {
        guard let gi = state.groups.firstIndex(where: { $0.id == groupID }),
              let ri = state.groups[gi].requests.firstIndex(where: { $0.id == requestID })
        else { return }
        state.groups[gi].requests[ri].status = status
        state.groups[gi].updatedAt = Date()
        save()
    }

    // MARK: Clips

    /// Copy a wav (given as bytes) into a group and return the stored clip.
    /// Throws if the group is unknown or the bytes can't be written.
    @discardableResult
    public func putClip(groupID: String, label: String, note: String? = nil,
                        wav: Data, source: LabClipSource = .unknown) throws -> LabClip {
        guard let gi = state.groups.firstIndex(where: { $0.id == groupID }) else {
            throw LabError.unknownGroup(groupID)
        }
        let id = UUID().uuidString
        let file = "\(id).wav"
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        try wav.write(to: clipsDir.appendingPathComponent(file), options: .atomic)
        let clip = LabClip(id: id, groupID: groupID, label: label, note: note,
                           file: file, source: source,
                           duration: WAVHeader.duration(of: wav))
        state.clips.append(clip)
        state.groups[gi].clipIDs.append(id)
        state.groups[gi].updatedAt = Date()
        save()
        return clip
    }

    /// Copy a wav already on disk into the store.
    @discardableResult
    public func putClip(groupID: String, label: String, note: String? = nil,
                        contentsOf url: URL, source: LabClipSource = .unknown) throws -> LabClip {
        try putClip(groupID: groupID, label: label, note: note,
                    wav: try Data(contentsOf: url), source: source)
    }

    /// Absolute URL of a stored clip's wav (for the tab's player).
    public func url(for clip: LabClip) -> URL {
        clipsDir.appendingPathComponent(clip.file)
    }

    public func clip(_ id: String) -> LabClip? {
        state.clips.first { $0.id == id }
    }

    public func setClipComment(clipID: String, comment: String?) {
        guard let i = state.clips.firstIndex(where: { $0.id == clipID }) else { return }
        state.clips[i].comment = comment
        save()
    }

    public func deleteClip(_ id: String) {
        guard let clip = clip(id) else { return }
        try? FileManager.default.removeItem(at: clipsDir.appendingPathComponent(clip.file))
        state.clips.removeAll { $0.id == id }
        if let gi = state.groups.firstIndex(where: { $0.id == clip.groupID }) {
            state.groups[gi].clipIDs.removeAll { $0 == id }
            state.groups[gi].updatedAt = Date()
        }
        save()
    }

    // MARK: Marks

    @discardableResult
    public func addMark(clipID: String, t: Double, note: String = "") -> LabMark? {
        guard let i = state.clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        let mark = LabMark(t: t, note: note)
        state.clips[i].marks.append(mark)
        save()
        return mark
    }

    public func removeMark(clipID: String, markID: String) {
        guard let i = state.clips.firstIndex(where: { $0.id == clipID }) else { return }
        state.clips[i].marks.removeAll { $0.id == markID }
        save()
    }

    // MARK: Feedback read-back

    /// Everything a developer left, for one group or all -- what the agent reads
    /// via `lab_read_feedback`.
    public func feedback(groupID: String? = nil) -> [LabGroupFeedback] {
        let groups = groupID.map { id in state.groups.filter { $0.id == id } } ?? state.groups
        return groups.map { g in
            LabGroupFeedback(
                groupID: g.id, heading: g.heading, verdict: g.verdict,
                openRequests: g.requests.filter { $0.status == .open }.map(\.text),
                clips: state.clips(of: g).map { c in
                    LabClipFeedback(clipID: c.id, label: c.label, comment: c.comment,
                                    marks: c.marks.sorted { $0.t < $1.t })
                })
        }
    }

    // MARK: Persistence

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(state).write(to: jsonURL, options: .atomic)
        } catch {
            // A dev-tool store; a write failure shouldn't take the app down.
            print("LabStore save failed: \(error)")
        }
    }

    private static func load(from url: URL) -> LabState {
        guard let data = try? Data(contentsOf: url) else { return LabState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(LabState.self, from: data)) ?? LabState()
    }
}

public enum LabError: Error, CustomStringConvertible {
    case unknownGroup(String)
    public var description: String {
        switch self {
        case .unknownGroup(let id): return "no Lab group with id '\(id)'"
        }
    }
}

/// Read-back shapes returned by `lab_read_feedback`.
public struct LabGroupFeedback: Codable, Sendable {
    public var groupID: String
    public var heading: String
    public var verdict: String?
    public var openRequests: [String]
    public var clips: [LabClipFeedback]
}

public struct LabClipFeedback: Codable, Sendable {
    public var clipID: String
    public var label: String
    public var comment: String?
    public var marks: [LabMark]
}

/// Minimal RIFF/WAVE header reader -- enough to report a clip's length on
/// ingest without pulling in AVFoundation. Scans chunks for `fmt ` (sample
/// rate, channels, bits) and `data` (byte length).
enum WAVHeader {
    static func duration(of data: Data) -> Double? {
        let bytes = [UInt8](data)
        guard bytes.count > 44,
              bytes[0...3] == [0x52, 0x49, 0x46, 0x46],           // "RIFF"
              bytes[8...11] == [0x57, 0x41, 0x56, 0x45] else {    // "WAVE"
            return nil
        }
        func u32(_ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o + 1]) << 8
                | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }

        var i = 12
        var sampleRate = 0, channels = 0, bits = 0, dataBytes = 0
        while i + 8 <= bytes.count {
            let id = Array(bytes[i ..< i + 4])
            let size = u32(i + 4)
            let body = i + 8
            if id == [0x66, 0x6D, 0x74, 0x20], body + 16 <= bytes.count {   // "fmt "
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == [0x64, 0x61, 0x74, 0x61] {                       // "data"
                dataBytes = min(size, bytes.count - body)
            }
            i = body + size + (size & 1)   // chunks are word-aligned
        }
        let bytesPerFrame = channels * max(bits / 8, 1)
        guard sampleRate > 0, bytesPerFrame > 0, dataBytes > 0 else { return nil }
        return Double(dataBytes / bytesPerFrame) / Double(sampleRate)
    }
}
