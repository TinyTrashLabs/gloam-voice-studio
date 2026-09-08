import Foundation

/// A place packs are read from and written to.
///
/// This is the ONE thing the format cannot decide for you: where the bytes
/// live. macOS keeps a `VoiceLibrary` of exploded pack directories in an app
/// container; the iOS app keeps its own store shaped around its own model.
/// Everything else about a `.gvoice` -- the manifest, the zip layout, the
/// entry limits, the pace and gain rules, the loudness standard -- is the
/// format's business and lives in this target, implemented once.
///
/// The member list is not a design; it is a measurement. These are exactly
/// the six operations `GVoice.export`/`GVoice.import` call, and no others.
/// `VoiceLibrary` already satisfies all six with these signatures, so its
/// conformance is empty -- which is the evidence the seam is in the right
/// place. If a conformance here needs a body, the line has moved wrong.
public protocol GVoicePackStore {
    /// Everything on disk for one slug: its metadata, its source audio if any,
    /// and its per-engine assets as `engine id -> [filename: URL]`.
    func entry(_ slug: String) throws
        -> (meta: VoiceMeta, refURL: URL?, engines: [String: [String: URL]])

    /// The variant family for a slug, keyed by variant name with "base" always
    /// present. A store with no notion of variants may return `["base": slug]`.
    func variantSlugs(of slug: String) -> [String: String]

    /// Store a new voice, minting its slug from `name`.
    func save(name: String, refWav: Data?, refText: String,
              provenance: JSONValue?,
              engines: [String: [String: Data]],
              pace: Double?,
              enginePace: [String: Double]?,
              gain: Double?,
              notes: String?) throws -> VoiceMeta

    /// Store a voice at a caller-chosen slug. Import needs this because a pack
    /// names its own variants and those names have to survive the trip.
    func saveAt(slug: String, name: String, refWav: Data?, refText: String,
                provenance: JSONValue?, variantOf: String?,
                engines: [String: [String: Data]],
                notes: String?) throws -> VoiceMeta

    /// The voice's avatar PNG on disk, nil when it has none. Export packs it
    /// as `GVoice.avatarMember`.
    func avatarURL(_ slug: String) -> URL?

    /// Store the avatar for an existing voice, replacing any it had. Import
    /// calls this after the base voice is saved; the bytes are already
    /// checked to be a PNG under `AvatarImage.maxBytes`.
    func saveAvatar(_ slug: String, pngData: Data) throws
}
