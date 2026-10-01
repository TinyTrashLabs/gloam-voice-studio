import Foundation

/// Qwen3-TTS VoiceDesign / CustomVoice attribute list: the exact keys Qwen
/// expects, with example values, and the canonical `key: value.` format.
/// Moved from the Mac app's VoiceDesignBuilder so Promo Studio shares it.
public enum VoiceDesignAttributes {
    public static let keys: [(key: String, example: String)] = [
        ("gender", "Male / female / gender-neutral"),
        ("pitch", "deep low register with upward lifts"),
        ("speed", "fast, punchy pauses"),
        ("volume", "loud, near-shouting at peaks"),
        ("age", "early 30s / elderly"),
        ("accent", "General American / British"),
        ("texture", "warm, smooth, low rumble"),
        ("emotion", "hyped and electric"),
        ("tone", "upbeat, performative"),
        ("personality", "confident, magnetic showman"),
        ("clarity", "crisp, distinct (optional)"),
        ("fluency", "effortless, no hesitation (optional)"),
    ]

    /// Non-empty values in `keys` order, one `key: value.` per line.
    public static func assemble(_ values: [String: String]) -> String {
        keys.compactMap { k -> String? in
            let v = (values[k.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : "\(k.key): \(v)."
        }
        .joined(separator: "\n")
    }
}
