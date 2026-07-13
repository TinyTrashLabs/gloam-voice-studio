import EngineKit
import StudioKit

/// Suffixes that mark a `<base>-<emotion>` acted variant — the current Fish
/// expression set plus the legacy `Emotion` names, so old variants still collapse.
private let voiceVariantSuffixes = Set(
    VoiceExpression.allCases.map { $0.rawValue } + Emotion.allCases.map { $0.rawValue })

/// The base voice a slug belongs to, if it's an acted `<base>-<emotion>` variant of
/// some other voice present in `all`. Shared by the sidebar (edit routing) and the
/// Direct-pane VOICE popover (grouped rendering).
func voiceBaseSlug(for slug: String, in all: [VoiceMeta]) -> String? {
    let slugs = Set(all.map { $0.slug })
    for suffix in voiceVariantSuffixes where slug.hasSuffix("-\(suffix)") {
        let base = String(slug.dropLast(suffix.count + 1))
        if !base.isEmpty && slugs.contains(base) { return base }
    }
    return nil
}

/// Base voices, each with its acted `<slug>-<emotion>` variants folded under it. A
/// voice is only a variant when its slug is `<base>-<emotion>` AND `<base>` exists —
/// so a hyphenated name like `sam-elliott` stays its own base voice. Shared by the
/// sidebar and the Direct-pane VOICE popover so both group identically.
func groupedVoices(_ all: [VoiceMeta]) -> [(base: VoiceMeta, variants: [VoiceMeta])] {
    var variantsByBase: [String: [VoiceMeta]] = [:]
    var bases: [VoiceMeta] = []
    for meta in all {
        if let base = voiceBaseSlug(for: meta.slug, in: all) {
            variantsByBase[base, default: []].append(meta)
        } else {
            bases.append(meta)
        }
    }
    return bases.map { base in
        (base, (variantsByBase[base.slug] ?? []).sorted { $0.slug < $1.slug })
    }
}
