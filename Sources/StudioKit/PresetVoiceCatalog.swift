import Foundation
import EngineKit

/// One built-in preset voice, as it is seeded into the library.
///
/// A preset is not a parameter. Kokoro's voicepacks, SuperTonic's style presets
/// and Qwen CustomVoice's speakers are *identities* — "who is talking" — and the
/// app used to model them as a picker value on the Direct pane, next to Speed.
/// That let the selected voice and the spoken voice disagree without anyone
/// noticing. They are stored as ordinary `.gvoice` packs instead, so there is
/// exactly one kind of voice identity and the two cannot drift apart.
public struct PresetVoice: Sendable, Equatable {
    /// Stable, engine-prefixed, and never derived from `name`: the display name
    /// is the user's to change, so it cannot be what identifies the pack.
    public let slug: String
    /// Initial display name. Freely renameable afterwards — the rename moves the
    /// pack directory but leaves `engines/<id>/voice.json` alone, so what the
    /// voice *renders as* is untouched.
    public let name: String
    /// `BackendID.rawValue` of the engine that ships this voice.
    public let engine: String
    /// The engine's own name for it, written to `engines/<engine>/voice.json`
    /// as `{"speaker": …}` — the authoritative binding.
    public let speaker: String
    /// Human description, stored as the pack's `notes`.
    public let notes: String

    public init(slug: String, name: String, engine: String, speaker: String, notes: String) {
        self.slug = slug; self.name = name; self.engine = engine
        self.speaker = speaker; self.notes = notes
    }
}

/// The built-in preset voices, and the descriptions that used to be hardcoded in
/// `StudioView`'s speaker pickers. They live here now because the description
/// belongs to the voice — visible when you inspect it, editable when you promote
/// it — not to whichever view happened to be rendering a picker.
public enum PresetVoiceCatalog {
    /// Bumped when the table below changes. Only packs still untouched by the
    /// user are refreshed; see `PresetVoiceSeeder`.
    public static let version = 1

    /// Slug prefix marking a pack as one of these. Chosen so it can never
    /// collide with a user's voice and so `VoiceGrouping.voiceBaseSlug` never
    /// mistakes one for an emotion variant of another.
    public static func slug(engine: String, speaker: String) -> String {
        let stem = speaker.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return "\(engine)-\(stem)"
    }

    // MARK: SuperTonic

    /// SuperTonic 3 ships ten fixed style presets, five male and five female.
    /// There is no cloning and no free-text direction — the preset IS the voice.
    static let supertonic: [PresetVoice] = BackendID.supertonicVoices.map { id in
        let female = id.hasPrefix("F")
        return PresetVoice(
            slug: slug(engine: BackendID.supertonic.rawValue, speaker: id),
            name: "SuperTonic \(id)",
            engine: BackendID.supertonic.rawValue,
            speaker: id,
            notes: "A fixed \(female ? "female" : "male") preset voice style shipped with "
                + "SuperTonic 3. Fast, multilingual, 44.1 kHz. SuperTonic does not clone "
                + "voices or take free-text direction — this preset is the voice.")
    }

    // MARK: Kokoro

    /// language, gender, and hexgrad's own per-voice quality grade (A best, F+
    /// weakest; "—" = ungraded). Source: hexgrad/Kokoro-82M's VOICES.md plus the
    /// vendored mlx-audio-swift README.
    static let kokoroInfo: [String: (language: String, gender: String, grade: String)] = [
        "af_heart": ("American English", "Female", "A"),
        "af_bella": ("American English", "Female", "A-"),
        "af_nicole": ("American English", "Female", "B-"),
        "af_aoede": ("American English", "Female", "C+"),
        "af_kore": ("American English", "Female", "C+"),
        "af_sarah": ("American English", "Female", "C+"),
        "af_alloy": ("American English", "Female", "C"),
        "af_nova": ("American English", "Female", "C"),
        "af_sky": ("American English", "Female", "C-"),
        "af_jessica": ("American English", "Female", "D"),
        "af_river": ("American English", "Female", "D"),
        "am_fenrir": ("American English", "Male", "C+"),
        "am_michael": ("American English", "Male", "C+"),
        "am_puck": ("American English", "Male", "C+"),
        "am_echo": ("American English", "Male", "D"),
        "am_eric": ("American English", "Male", "D"),
        "am_liam": ("American English", "Male", "D"),
        "am_onyx": ("American English", "Male", "D"),
        "am_santa": ("American English", "Male", "D-"),
        "am_adam": ("American English", "Male", "F+"),
        "bf_emma": ("British English", "Female", "B-"),
        "bf_isabella": ("British English", "Female", "C"),
        "bf_alice": ("British English", "Female", "D"),
        "bf_lily": ("British English", "Female", "D"),
        "bm_fable": ("British English", "Male", "C"),
        "bm_george": ("British English", "Male", "C"),
        "bm_lewis": ("British English", "Male", "D+"),
        "bm_daniel": ("British English", "Male", "D"),
        "ff_siwis": ("French", "Female", "B-"),
        "hf_alpha": ("Hindi", "Female", "C"),
        "hf_beta": ("Hindi", "Female", "C"),
        "hm_omega": ("Hindi", "Male", "C"),
        "hm_psi": ("Hindi", "Male", "C"),
        "if_sara": ("Italian", "Female", "C"),
        "im_nicola": ("Italian", "Male", "C"),
        "jf_alpha": ("Japanese", "Female", "C+"),
        "jf_gongitsune": ("Japanese", "Female", "C"),
        "jf_tebukuro": ("Japanese", "Female", "C"),
        "jf_nezumi": ("Japanese", "Female", "C-"),
        "jm_kumo": ("Japanese", "Male", "C-"),
        "ef_dora": ("Spanish", "Female", "—"),
        "em_alex": ("Spanish", "Male", "—"),
        "em_santa": ("Spanish", "Male", "—"),
        "pf_dora": ("Portuguese", "Female", "—"),
        "pm_alex": ("Portuguese", "Male", "—"),
        "pm_santa": ("Portuguese", "Male", "—"),
        "zf_xiaobei": ("Chinese", "Female", "D"),
        "zf_xiaoni": ("Chinese", "Female", "D"),
        "zf_xiaoxiao": ("Chinese", "Female", "D"),
        "zf_xiaoyi": ("Chinese", "Female", "D"),
        "zm_yunjian": ("Chinese", "Male", "D"),
        "zm_yunxi": ("Chinese", "Male", "D"),
        "zm_yunxia": ("Chinese", "Male", "D"),
        "zm_yunyang": ("Chinese", "Male", "D"),
    ]

    /// "af_heart" -> "Heart". The prefix encodes language and gender, both of
    /// which the display name carries in readable form instead.
    static func kokoroStem(_ id: String) -> String {
        let stem = id.split(separator: "_").dropFirst().joined(separator: " ")
        guard let first = stem.first else { return id }
        return first.uppercased() + stem.dropFirst()
    }

    static let kokoro: [PresetVoice] = BackendID.kokoroVoices.map { id in
        let info = kokoroInfo[id]
        let language = info?.language ?? "Unknown"
        // The language is part of the NAME, not just the notes: `af_dora`,
        // `ef_dora` and `pf_dora` (and the three Santas, and both Alexes, and
        // both Alphas) share a stem, so without it the sidebar would show
        // several identically-named voices.
        let name = "\(kokoroStem(id)) · \(language)"
        var notes = "\(language) \(info?.gender.lowercased() ?? "voice"), voicepack `\(id)`."
        if let grade = info?.grade, grade != "—" {
            notes += " Graded \(grade) by the model's author (A best, F+ weakest)."
        }
        notes += " Kokoro speaks its own fixed voices — no cloning, no direction."
        return PresetVoice(slug: slug(engine: BackendID.kokoro.rawValue, speaker: id),
                           name: name, engine: BackendID.kokoro.rawValue,
                           speaker: id, notes: notes)
    }

    // MARK: Qwen CustomVoice

    static let qwenInfo: [String: (desc: String, lang: String)] = [
        "Vivian": ("Bright, slightly edgy young female", "Chinese"),
        "Serena": ("Warm, gentle young female", "Chinese"),
        "Uncle_Fu": ("Seasoned male, low mellow timbre", "Chinese"),
        "Dylan": ("Youthful, clear male", "Beijing dialect"),
        "Eric": ("Lively, slightly husky male", "Sichuan dialect"),
        "Ryan": ("Dynamic male, strong rhythmic drive", "English"),
        "Aiden": ("Sunny American male, clear midrange", "English"),
        "Ono_Anna": ("Playful, light female", "Japanese"),
        "Sohee": ("Warm, emotional female", "Korean"),
    ]

    static let qwenCustom: [PresetVoice] = BackendID.qwenPresetSpeakers.map { id in
        let info = qwenInfo[id]
        let display = id.replacingOccurrences(of: "_", with: " ")
        var notes = info.map { "\($0.desc). \($0.lang)." } ?? ""
        notes += " A fixed CustomVoice identity — Direction shapes how it delivers a "
            + "line, but not who is speaking."
        return PresetVoice(slug: slug(engine: BackendID.qwenCustom.rawValue, speaker: id),
                           name: "\(display) · Qwen",
                           engine: BackendID.qwenCustom.rawValue,
                           speaker: id, notes: notes.trimmingCharacters(in: .whitespaces))
    }

    public static let all: [PresetVoice] = supertonic + kokoro + qwenCustom
}
