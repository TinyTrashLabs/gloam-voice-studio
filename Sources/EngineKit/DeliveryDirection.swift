import Foundation

/// The words a `.directed` backend (Breeze) is given for each emotion control.
///
/// Breeze has no emotion knob and no marker tokens: its trained control is the
/// natural-language instruction ("voice direction"). So the app's existing
/// emotion controls — the five-step Emotion picker, the acted expressions the
/// Create Voice baker offers, the API/MCP `emotion` field — are translated into
/// short directions and composed with the user's own Direction. One place, so
/// the Studio, the baker and the API all ask for an emotion in the same words.
public enum DeliveryDirection {
    /// The sentence an `Emotion` contributes. `.neutral` contributes nothing —
    /// it is the model's own read, and an empty instruction also keeps Breeze
    /// off its classifier-free-guidance path (half the work per frame).
    public static func phrase(for emotion: Emotion) -> String? {
        switch emotion {
        case .flat: "Flat, even and restrained, with very little emotion."
        case .neutral: nil
        case .warm: "Warm, friendly and gentle."
        case .excited: "Excited and energetic, with lively pacing."
        case .hype: "Hyped up and bursting with energy — loud, fast and intense."
        }
    }

    /// Directions for the named expressions the app knows (the Create Voice
    /// baker's `VoiceExpression` cases). Keys are those raw values.
    static let expressions: [String: String] = [
        "excited": "Excited and energetic.",
        "delight": "Delighted, beaming with joy.",
        "angry": "Angry — sharp, forceful and tense.",
        "sad": "Sad and downcast, quiet and slow.",
        "surprised": "Surprised, caught off guard.",
        "shocked": "Shocked and stunned, breath catching.",
        "whisper": "Whispering, very quiet and breathy.",
        "shouting": "Shouting loudly.",
        "screaming": "Screaming at the top of their lungs.",
        "laughing": "Laughing through the words.",
        "chuckle": "With a light chuckle in the voice.",
        "sigh": "With a weary sigh, tired and resigned.",
        "panting": "Out of breath, panting between words.",
        "moaning": "Moaning, low and drawn out.",
        "singing": "Singing the words with a melody.",
    ]

    /// The sentence an expression (`SynthesisRequest.emotionMarker`)
    /// contributes. A known name gets its tuned wording; anything else is
    /// free text a caller chose ("whisper in a small voice") and is passed
    /// through as a direction, since Breeze reads natural language.
    public static func phrase(forExpression expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let known = expressions[trimmed.lowercased()] { return known }
        return sentence("Delivery: \(trimmed)")
    }

    /// The user's Direction first (it is the most specific), then the
    /// expression, then the emotion — each closed as its own sentence, so a
    /// Direction written as a phrase ("warm, unhurried radio host") doesn't
    /// run on into "Whispering, …". nil when there is nothing to say.
    public static func compose(direction: String?, expression: String?,
                               emotion: Emotion) -> String? {
        let parts = [direction,
                     expression.flatMap { phrase(forExpression: $0) },
                     phrase(for: emotion)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // A lone Direction is passed exactly as written.
        guard parts.count > 1 else { return parts[0] }
        return parts.map(sentence).joined(separator: " ")
    }

    /// `text` ending in sentence punctuation: unchanged when it already does
    /// (Latin or full-width, closing quotes allowed), otherwise with a "." —
    /// or "。" after Chinese, so a Chinese Direction stays Chinese.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "」"]
        let core = trimmed.reversed().drop(while: { closers.contains($0) })
        guard let last = core.first else { return trimmed }
        if ".!?…。！？".contains(last) { return trimmed }
        let isCJK = last.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        return trimmed + (isCJK ? "。" : ".")
    }
}
