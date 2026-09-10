import Foundation

/// The Lab is an in-app audio comparison shelf: wavs collected from any source
/// (an agent over MCP, a Finder drop, a "Send to Lab" render) grouped into
/// named comparisons, with the marks/comments/verdicts a developer leaves while
/// auditioning them. It does not synthesize audio -- clips are produced
/// elsewhere and land here. See docs/superpowers/specs/2026-09-07-lab-comparison-tab-design.md.

/// Where a clip came from -- provenance shown in the tab and returned by
/// `lab_list`, so a comparison of "my spike vs the app's own render vs a Qwen
/// clip" stays legible.
public enum LabClipSource: String, Codable, Sendable, CaseIterable {
    case mcp        // pushed by an agent over MCP / the HTTP API
    case finder     // dragged in from Finder
    case dialogue   // "Send to Lab" from the Dialogue area
    case studio     // "Send to Lab" from a single-line Studio render
    case unknown
}

/// A timestamp the listener pinned on a clip while auditioning it.
public struct LabMark: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// Seconds into the clip.
    public var t: Double
    public var note: String
    public var at: Date

    public init(id: String = UUID().uuidString, t: Double, note: String = "",
                at: Date = Date()) {
        self.id = id
        self.t = t
        self.note = note
        self.at = at
    }
}

/// An actionable ask the developer aims at the agent from inside a comparison
/// ("render 3 more draws of B", "change Benson's line 4 and re-render"). Read
/// back by `lab_read_feedback` as work to do.
public struct LabRequest: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case open, done }
    public var id: String
    public var text: String
    public var status: Status
    public var at: Date

    public init(id: String = UUID().uuidString, text: String,
                status: Status = .open, at: Date = Date()) {
        self.id = id
        self.text = text
        self.status = status
        self.at = at
    }
}

/// One audio file in a comparison. The Lab owns its bytes: the wav is copied
/// into the store on ingest, so a source file moving or being deleted never
/// breaks a saved comparison. `file` is the basename inside the store's
/// `clips/` directory.
public struct LabClip: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var groupID: String
    public var label: String
    public var note: String?
    /// Basename inside `<store>/clips/`.
    public var file: String
    public var source: LabClipSource
    /// Clip length in seconds, computed on ingest.
    public var duration: Double?
    /// A whole-clip comment (not tied to a timestamp).
    public var comment: String?
    public var marks: [LabMark]
    public var addedAt: Date

    public init(id: String = UUID().uuidString, groupID: String, label: String,
                note: String? = nil, file: String, source: LabClipSource = .unknown,
                duration: Double? = nil, comment: String? = nil,
                marks: [LabMark] = [], addedAt: Date = Date()) {
        self.id = id
        self.groupID = groupID
        self.label = label
        self.note = note
        self.file = file
        self.source = source
        self.duration = duration
        self.comment = comment
        self.marks = marks
        self.addedAt = addedAt
    }
}

/// The unit of the Lab: one comparison. A heading + a "listen for" instruction
/// + an ordered set of clips (A, B, C…), plus the developer's verdict and any
/// requests aimed at the agent. Persists until explicitly deleted.
public struct LabGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var heading: String
    public var listenFor: String
    /// Clip order (A, B, C…). The clips themselves live in `LabState.clips`,
    /// keyed by id, so a clip carries its own `groupID` back-reference too.
    public var clipIDs: [String]
    /// The developer decision ("B wins, ship the baked ref").
    public var verdict: String?
    public var requests: [LabRequest]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, heading: String, listenFor: String = "",
                clipIDs: [String] = [], verdict: String? = nil,
                requests: [LabRequest] = [], createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.heading = heading
        self.listenFor = listenFor
        self.clipIDs = clipIDs
        self.verdict = verdict
        self.requests = requests
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The whole on-disk model, serialized to `lab.json`. Groups and clips are
/// stored side by side (clips keyed by id) so a clip can be addressed directly
/// by the MCP tools without walking every group.
public struct LabState: Codable, Equatable, Sendable {
    public var groups: [LabGroup]
    public var clips: [LabClip]

    public init(groups: [LabGroup] = [], clips: [LabClip] = []) {
        self.groups = groups
        self.clips = clips
    }

    /// Clips of a group, in the group's declared order, skipping any dangling id.
    public func clips(of group: LabGroup) -> [LabClip] {
        group.clipIDs.compactMap { id in clips.first { $0.id == id } }
    }
}
