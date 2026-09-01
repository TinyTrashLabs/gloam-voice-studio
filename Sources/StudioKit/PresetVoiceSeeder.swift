import Foundation

/// Writes the built-in preset voices into the library as ordinary `.gvoice`
/// packs.
///
/// The whole point of storing them on disk rather than rendering them from a
/// table is that a preset can be *promoted*: renamed, given an avatar, notes, a
/// persona, a recorded reference, extra baked renditions. So the one rule this
/// seeder must never break is that it does not overwrite a voice the user has
/// touched. It is deliberately conservative about what counts as touched.
public enum PresetVoiceSeeder {
    /// Marker written into `provenance` so a later run can tell a pack it seeded
    /// from a voice the user made or edited. A pack without it is never written
    /// to, whatever its slug.
    static let catalogID = "gloam-builtin"

    public struct Report: Sendable, Equatable {
        public var created: Int = 0
        public var refreshed: Int = 0
        public var skipped: Int = 0
    }

    @discardableResult
    public static func seed(into library: VoiceLibrary,
                            catalog: [PresetVoice] = PresetVoiceCatalog.all,
                            version: Int = PresetVoiceCatalog.version) -> Report {
        var report = Report()
        for preset in catalog {
            switch state(of: preset, in: library, version: version) {
            case .absent:
                if write(preset, version: version, into: library) { report.created += 1 }
            case .untouched(let stale):
                if stale, write(preset, version: version, into: library) { report.refreshed += 1 }
                else { report.skipped += 1 }
            case .userOwned:
                report.skipped += 1
            }
        }
        return report
    }

    // MARK: what is safe to write

    private enum State {
        case absent
        /// Seeded by us and unchanged since. `stale` = seeded at an older
        /// catalog version, so the name/notes/binding are worth refreshing.
        case untouched(stale: Bool)
        /// Either the user's own voice at this slug, or a seeded preset they
        /// have since edited. Never written to.
        case userOwned
    }

    /// True for a pack this seeder wrote that nobody has edited since — the
    /// sidebar's "Bundled" section. The moment a user touches it (rename,
    /// avatar, notes, persona, gain, a recorded reference) it is theirs and
    /// lists with their own voices. Same test the seeder uses to decide what it
    /// may overwrite, so "bundled" and "safe to refresh" can never disagree.
    public static func isBundled(_ meta: VoiceMeta, in library: VoiceLibrary) -> Bool {
        if case .untouched = state(meta: meta, in: library, version: nil) { return true }
        return false
    }

    private static func state(of preset: PresetVoice, in library: VoiceLibrary,
                              version: Int) -> State {
        guard let meta = try? library.meta(preset.slug) else { return .absent }
        return state(meta: meta, in: library, version: version)
    }

    /// `version == nil` skips the staleness check (callers that only ask
    /// "is this still ours?").
    private static func state(meta: VoiceMeta, in library: VoiceLibrary,
                              version: Int?) -> State {
        guard case .object(let provenance)? = meta.provenance,
              case .object(let mark)? = provenance["preset"],
              case .string(PresetVoiceSeeder.catalogID)? = mark["catalog"]
        else { return .userOwned }   // the user's own voice happens to sit here

        // Any sign of a human having been here and it is theirs from now on.
        // Checked against the catalog rather than a stored flag so an edit made
        // by any route — the editor sheet, a future importer, a hand-edited
        // meta.json — counts.
        let entry = try? library.entry(meta.slug)
        let hasReference = entry?.refURL != nil
        let hasAvatar = library.avatarURL(meta.slug) != nil
        let seededVersion: Int? = {
            if case .number(let n)? = mark["version"] { return Int(n) }
            return nil
        }()
        // Compared against what WE last wrote, recorded in the mark — not
        // against the current catalog. Comparing to the catalog would read every
        // catalog rewording as a user edit, and the pack would freeze at
        // whatever text shipped first.
        let seededName: String? = { if case .string(let v)? = mark["name"] { return v }; return nil }()
        let seededNotes: String? = { if case .string(let v)? = mark["notes"] { return v }; return nil }()
        guard !hasReference, !hasAvatar, meta.persona == nil, meta.gain == nil,
              meta.name == seededName, meta.notes == seededNotes
        else { return .userOwned }

        return .untouched(stale: version.map { seededVersion != $0 } ?? false)
    }

    // MARK: writing

    private static func write(_ preset: PresetVoice, version: Int,
                              into library: VoiceLibrary) -> Bool {
        // The binding, and the only asset a preset pack has: the engine's own
        // name for the voice. `docs/gvoice-format.md` has always described this
        // shape — engines/<id>/voice.json { "speaker": … }.
        guard let voiceJSON = try? JSONSerialization.data(
            withJSONObject: ["speaker": preset.speaker]) else { return false }
        let provenance = JSONValue.object([
            "preset": .object([
                "catalog": .string(catalogID),
                "version": .number(Double(version)),
                "engine": .string(preset.engine),
                "speaker": .string(preset.speaker),
                // What we wrote, so a later run can tell "the user renamed this"
                // from "the catalog reworded it".
                "name": .string(preset.name),
                "notes": .string(preset.notes),
            ]),
        ])
        do {
            _ = try library.saveAt(slug: preset.slug, name: preset.name,
                                   refWav: nil, refText: "",
                                   provenance: provenance,
                                   engines: [preset.engine: ["voice.json": voiceJSON]],
                                   notes: preset.notes)
            return true
        } catch {
            return false
        }
    }
}
