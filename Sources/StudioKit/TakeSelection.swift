import Foundation
import NaturalLanguage

/// The take a line renders from, chosen by the line's language and the picked style
/// (docs/gvoice-format.md, "Choosing a take: language × style"). One choice for every
/// surface that renders a library voice — the Studio bench, Chat, Script, `/v1/audio/speech`
/// and the MCP `speak` tool — so they never disagree about which recording spoke.
public struct TakeChoice: Equatable, Sendable {
    /// Which rule of the format's order picked the take.
    public enum Step: Int, Sendable {
        /// The take in the line's language with the picked style.
        case languageAndStyle = 1
        /// The line's language, natural delivery (no take of the style in it).
        case language = 2
        /// The picked style in the voice's home language.
        case homeStyle = 3
        /// The voice itself.
        case base = 4
    }

    public let take: VoiceTakeGrid.Take
    public let step: Step
    /// The line's language as a primary code ("es"), nil when unknown.
    public let language: String?
    /// The style that was asked for, nil for natural delivery.
    public let style: String?

    /// The library address that renders ("benson-es-excited", or the voice's own slug).
    public var slug: String { take.slug }
    /// The take performs the picked style itself, so it must not be directed on top.
    public var carriesStyle: Bool { step == .languageAndStyle || step == .homeStyle }
}

extension VoiceTakeGrid {
    /// The format's order for a line in `language` with `style` picked: (L, S) → (L) → home S →
    /// base. Decided from each take's row and column — its `language` and `style` fields, the key
    /// only for takes that predate `style` (see `init(base:variants:)`).
    ///
    /// - `language`: a BCP-47 tag or one of Studio's picker names ("spanish"); compared by primary
    ///   subtag, so an "es-MX" line finds an "es" take. Nil, or the home language, skips (L).
    /// - `style`: a style name. Nil, "" and "neutral" mean natural delivery — on the Mac "neutral" has
    ///   always been the voice itself, and it is the Direct panel's default. "hype" and "excited"
    ///   stand in for each other (`VoiceLibrary.emotionSuffixes`), tried right after the exact name
    ///   at the same step.
    /// - `usable`: drops takes the caller can't render from (a cloning engine needs a recording).
    ///   `base` is returned even when unusable; the caller reports that.
    public func choose(language: String?, style: String?,
                       usable: (Take) -> Bool = { _ in true }) -> TakeChoice {
        let wanted = VoiceLibrary.primaryLanguage(language)
        let styles = VoiceLibrary.emotionSuffixes(style)
        let picked = styles.first
        let base = takes.first { $0.isDefault }!
        func first(_ rows: [Row], _ column: (Column) -> Bool) -> Take? {
            takes.filter { rows.contains($0.row) && column($0.column) && usable($0) }
                .sorted { ($0.isDefault ? "" : $0.key) < ($1.isDefault ? "" : $1.key) }.first
        }
        func choice(_ take: Take, _ step: TakeChoice.Step) -> TakeChoice {
            TakeChoice(take: take, step: step, language: wanted, style: picked)
        }
        let homeRow = rows.first { $0.isHome }!
        if let wanted, wanted != VoiceLibrary.primaryLanguage(home) {
            // An exact tag first ("es-mx" for an "es-MX" line), then any row of that language.
            let exact = VoiceLibrary.languageKey(language ?? "")
            let lineRows = rows.filter { !$0.isHome && VoiceLibrary.primaryLanguage($0.language) == wanted }
                .sorted { ($0.language == exact ? 0 : 1, $0.language ?? "") < ($1.language == exact ? 0 : 1, $1.language ?? "") }
            for row in lineRows {
                for name in styles {
                    if let take = first([row], { $0.name == name }) { return choice(take, .languageAndStyle) }
                }
            }
            for row in lineRows {
                if let take = first([row], \.isNatural) { return choice(take, .language) }
            }
        }
        for name in styles {
            if let take = first([homeRow], { $0.name == name }) { return choice(take, .homeStyle) }
        }
        return choice(base, .base)
    }
}

extension VoiceLibrary {
    /// The take of voice `slug` for a line in `language` with `style` picked — see
    /// `VoiceTakeGrid.choose`. Nil when `slug` isn't a voice (a take picked directly, or unknown):
    /// the caller then renders from that address as given.
    public func chooseTake(of slug: String, language: String?, style: String?,
                           usable: (VoiceTakeGrid.Take) -> Bool = { _ in true }) -> TakeChoice? {
        takeGrid(of: slug)?.choose(language: language, style: style, usable: usable)
    }

    /// `chooseTake` restricted to takes with a recording (`ref.wav`), with the take's meta and
    /// reference — what a cloning engine renders from. Nil when `slug` isn't a voice.
    public func chooseRecordedTake(of slug: String, language: String?, style: String?)
        -> (choice: TakeChoice, meta: VoiceMeta, refURL: URL?)?
    {
        guard let choice = chooseTake(of: slug, language: language, style: style,
                                      usable: { (try? self.get($0.slug)) != nil }) else { return nil }
        if let found = try? get(choice.slug) { return (choice, found.meta, found.refURL) }
        // The voice itself has no recording (a rendition-only pack).
        guard let meta = try? meta(choice.slug) else { return nil }
        return (choice, meta, nil)
    }
}

/// The language a line is in: what the Language control says, or — on Auto — what the text
/// itself clearly is. Same bar as the iPhone's Compose (`ComposeLanguage`) and
/// `ScriptLanguage.qwenName`: a confident (≥ 0.8) guess on at least three words, so a greeting
/// or a name in another language never flips the voice's recording.
public enum LineLanguage {
    public static let minConfidence = 0.8
    public static let minWords = 3
    /// The opening is enough to tell, and keeps a long script cheap to check.
    public static let sampleLimit = 2000

    /// The line's language as a primary code ("es"): the picker's choice ("spanish", "es-MX"),
    /// or on "auto"/nil/blank the text's detected language. Nil when neither says.
    public static func of(_ text: String, picker: String?) -> String? {
        if let picked = VoiceLibrary.primaryLanguage(picker), picked != "auto" { return picked }
        return detect(text)
    }

    /// The text's language as a primary code ("es", "zh"), or nil when it is too short or the
    /// recogniser isn't sure enough to act on.
    public static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(sampleLimit))
        guard wordCount(sample) >= minWords else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(sample)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= minConfidence else { return nil }
        return VoiceLibrary.primaryLanguage(lang.rawValue)
    }

    /// Words as NaturalLanguage segments them, so a line with no spaces (Japanese, Chinese)
    /// counts in words too. Stops at `minWords`: only "enough or not" matters.
    static func wordCount(_ text: String) -> Int {
        let t = NLTokenizer(unit: .word)
        t.string = text
        var n = 0
        t.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            n += 1
            return n < minWords
        }
        return n
    }

    /// What a language-taking engine (Qwen) is told. A language the user picked passes through
    /// as before. On Auto, a confidently detected language other than English is named the way
    /// Qwen's codec does ("spanish"); English and anything unknown stay `picker` ("auto"), which
    /// is what every English render has been tuned against.
    public static func engineLanguage(picker: String?, detected: String?) -> String? {
        if let picked = VoiceLibrary.primaryLanguage(picker), picked != "auto" { return picker }
        guard let detected, detected != "en", let name = qwenNames[detected] else { return picker }
        return name
    }

    /// Qwen's `codec_language_id` names, by primary code (QwenANE `HostTables.names`).
    static let qwenNames: [String: String] = [
        "zh": "chinese", "en": "english", "de": "german", "it": "italian", "pt": "portuguese",
        "es": "spanish", "ja": "japanese", "ko": "korean", "fr": "french", "ru": "russian",
    ]

    /// "Spanish" for "es" — the help text and logs name the language, not its code.
    public static func name(_ code: String?, locale: Locale = Locale(identifier: "en")) -> String? {
        guard let code else { return nil }
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }
}

extension VoiceTakeGrid {
    /// What the Direct panel's Emotion picker really does for this voice with `style` picked, in
    /// words: "Uses Benson's Excited take. Uses Benson's Spanish · Excited take when the line is
    /// Spanish." Built from `choose`, so the help text can't promise a take the render won't use.
    public func styleSummary(voiceName: String, style: String?) -> String {
        let styleName = VoiceLibrary.emotionSuffixes(style).first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        func label(_ c: TakeChoice) -> String {
            var parts: [String] = []
            if !c.take.row.isHome, let name = LineLanguage.name(VoiceLibrary.primaryLanguage(c.take.row.language)) {
                parts.append(name)
            }
            if c.carriesStyle { parts.append(c.take.column.title) }
            return parts.joined(separator: " · ")
        }
        let home = choose(language: nil, style: style)
        var sentences: [String] = []
        if home.step == .homeStyle {
            sentences.append("Uses \(voiceName)'s \(label(home)) take.")
        } else if let styleName {
            sentences.append("\(voiceName) has no \(styleName) take, so the voice's own recording reads it.")
        } else {
            sentences.append("Uses \(voiceName)'s own recording.")
        }
        let languages = Set(rows.filter { !$0.isHome }.compactMap { VoiceLibrary.primaryLanguage($0.language) })
        for code in languages.sorted() {
            let c = choose(language: code, style: style)
            guard c.step == .languageAndStyle || c.step == .language,
                  let name = LineLanguage.name(code) else { continue }
            sentences.append("Uses \(voiceName)'s \(label(c)) take when the line is \(name).")
        }
        return sentences.joined(separator: " ")
    }
}
