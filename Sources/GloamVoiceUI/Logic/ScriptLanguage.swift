import NaturalLanguage

/// The bundled recogniser is English-only; a script in another language gets
/// the signal checks and no transcript check, rather than a false "skipped words".
public enum ScriptLanguage {
    public static func isEnglish(_ text: String) -> Bool {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage == .english
    }
}
