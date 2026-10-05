import Foundation
import GVoiceKit

/// One recording a voice is learned from. The master (`ref.wav`) is rebuilt
/// from every take on Save; a take itself is kept as recorded, 24 kHz mono,
/// so a later rebuild starts from the same material and not from a previous
/// rebuild's cleanup.
public struct VoiceTake: Codable, Identifiable, Equatable {
    public enum Origin: String, Codable {
        /// Read into the mic on this phone.
        case recorded
        /// A file the person picked.
        case imported
        /// The pack's own master, adopted as take 1 when the first take was
        /// added to a voice that came with one.
        case master
    }
    /// Ordinal, never reused: the file is `takes/<id>.wav`.
    public let id: Int
    public var transcript: String
    public let seconds: Double
    public let addedAt: String
    public let origin: Origin

    public var file: String { "\(id).wav" }

    public init(id: Int, transcript: String, seconds: Double, addedAt: String, origin: Origin) {
        self.id = id; self.transcript = transcript; self.seconds = seconds
        self.addedAt = addedAt; self.origin = origin
    }
}

/// `takes.json` -- phone-only bookkeeping beside the pack members. Not a pack
/// member itself: `GVoice.export` reads `ref.wav`, `engines/` and the avatar
/// and nothing else, so the directory still zips as-is.
public struct VoiceTakes: Codable, Equatable {
    public var takes: [VoiceTake] = []
    public var nextID: Int = 1
    /// A take was added, removed or re-transcribed since the master was last
    /// rebuilt from them. Save clears it.
    public var masterStale = false

    public init(takes: [VoiceTake] = [], nextID: Int = 1, masterStale: Bool = false) {
        self.takes = takes; self.nextID = nextID; self.masterStale = masterStale
    }

    /// Combined length of the takes once joined (with the combiner's gaps).
    public var combinedSeconds: Double { TakeRules.combinedSeconds(takes.map(\.seconds)) }
}
