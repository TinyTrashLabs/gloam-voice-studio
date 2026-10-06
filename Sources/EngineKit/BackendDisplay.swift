import Foundation

extension BackendID {
    /// The engine's name as a person reads it — "Qwen 0.6B ANE", not
    /// "qwen3-0.6b-ane". The raw id stays the wire/storage identifier; this is
    /// only ever shown. Exhaustive on purpose: a new backend can't ship without
    /// someone deciding what to call it.
    public var displayName: String {
        switch self {
        case .qwen06B: "Qwen 0.6B"
        case .qwen06BMobile: "Qwen 0.6B Mobile"
        case .qwen06BANE: "Qwen 0.6B ANE"
        case .qwen17B: "Qwen 1.7B"
        case .qwenDesign: "Qwen Design"
        case .qwenCustom: "Qwen Custom"
        case .chatterboxTurbo: "Chatterbox Turbo"
        case .fishS2Pro: "Fish S2 Pro"
        case .breezeTTS2: "Breeze"
        case .chatterbox: "Chatterbox"
        case .kokoro: "Kokoro"
        case .supertonic: "SuperTonic"
        case .luxTTS: "LuxTTS"
        case .pocketTTS: "Pocket"
        case .dia2: "Dia 2"
        }
    }

    /// The family word a display name starts with ("Qwen", "Chatterbox"), for
    /// deduplicating labels like a preset voice named "Aiden · Qwen".
    public var familyName: String {
        String(displayName.split(separator: " ").first ?? Substring(displayName))
    }

    /// Fallback preference when a voice needs an engine and the user has no
    /// history with any that can speak it: the bench's own default first (the
    /// same `.qwen17B` init falls back to), then the lighter Qwen bakes, then
    /// the other cloners from best-sounding to lightest. Engines with a license
    /// gate come last so an automatic switch never lands on a license prompt
    /// before a free alternative.
    public static let autoSwitchPreference: [BackendID] = [
        .qwen17B, .qwen06B, .qwen06BMobile, .qwen06BANE,
        .chatterboxTurbo, .chatterbox, .luxTTS, .pocketTTS,
        .kokoro, .qwenCustom, .breezeTTS2, .fishS2Pro, .supertonic,
    ]

    /// The engine to switch to automatically when the selected voice can't be
    /// spoken by `current`, or nil when there is nothing sensible to switch to.
    ///
    /// - `candidates`: engines that can speak the voice AND can be switched to
    ///   right now (Studio engine, downloaded, enough RAM) — the caller owns
    ///   those checks; this owns the ordering.
    /// - `recent`: engines the user picked, most recent first. The latest one
    ///   that can speak the voice wins — it's what they last chose on purpose.
    /// - `preRendered`: engines the voice's pack carries a baked rendition for;
    ///   those beat a fresh clone when there's no history to go on.
    public static func autoSwitchTarget(current: BackendID,
                                        candidates: [BackendID],
                                        recent: [BackendID],
                                        preRendered: Set<BackendID> = []) -> BackendID? {
        let pool = candidates.filter { $0 != current }
        guard !pool.isEmpty, !candidates.contains(current) else { return nil }
        if let remembered = recent.first(where: pool.contains) { return remembered }
        let rank: (BackendID) -> Int = {
            autoSwitchPreference.firstIndex(of: $0) ?? autoSwitchPreference.count
        }
        let baked = pool.filter(preRendered.contains)
        let ordered = (baked.isEmpty ? pool : baked)
            .enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        return ordered.first?.element
    }

    /// Prepend `backend` to a most-recent-first history, without duplicates,
    /// capped at `limit`.
    public static func recordingRecent(_ backend: BackendID, in recent: [BackendID],
                                       limit: Int = 8) -> [BackendID] {
        Array(([backend] + recent.filter { $0 != backend }).prefix(limit))
    }
}
