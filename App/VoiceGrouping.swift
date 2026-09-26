import EngineKit
import StudioKit

/// The voice a take address belongs to (`nova-excited` → `nova`), or nil for a
/// voice. Takes live inside their voice's folder, so this is a lookup, not a
/// guess from the slug. Shared by the sidebar (edit routing) and the
/// Direct-pane VOICE popover.
func voiceBaseSlug(for slug: String, in library: VoiceLibrary) -> String? {
    if case .variant(let base, _)? = library.locate(slug) { return base }
    return nil
}

/// Each voice with the takes inside its folder. `all` is the library's voice
/// list (voices only); the takes come from the folder, so a voice named
/// `sam-elliott` beside `sam` can never be mistaken for a take.
func groupedVoices(_ all: [VoiceMeta], library: VoiceLibrary) -> [(base: VoiceMeta, variants: [VoiceMeta])] {
    all.map { base in
        let takes = library.layout.variantKeys(of: base.slug)
            .compactMap { try? library.meta("\(base.slug)-\($0)") }
        return (base, takes)
    }
}
