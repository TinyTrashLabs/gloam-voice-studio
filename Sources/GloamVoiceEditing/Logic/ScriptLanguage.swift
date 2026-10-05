import NaturalLanguage

/// The bundled recogniser is English-only; a script in another language gets
/// the signal checks and no transcript check, rather than a false "skipped words".
public enum ScriptLanguage {
    public static func isEnglish(_ text: String) -> Bool {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage == .english
    }

    /// Qwen's codec language name ("spanish") for a script that is clearly
    /// in one of Qwen's languages other than English; nil leaves Qwen on
    /// "auto". English stays on auto on purpose: that is what every English
    /// render has been tuned and checked against. The Mac passes the take's
    /// language (gloam-voice-studio #81); a phone script has no take, so the
    /// text is asked instead, and only a confident answer is used.
    public static func qwenName(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.8 else { return nil }
        let names: [NLLanguage: String] = [
            .spanish: "spanish", .simplifiedChinese: "chinese", .traditionalChinese: "chinese",
            .german: "german", .italian: "italian", .portuguese: "portuguese",
            .japanese: "japanese", .korean: "korean", .french: "french", .russian: "russian",
        ]
        return names[lang]
    }
}
