import EngineKit

/// Fixed script + guidance for recording acted emotion variants. The same
/// passage is used for every emotion — keeping the words identical isolates
/// delivery as the one variable between recordings — only the delivery note
/// changes. ~85 words of emotionally neutral prose, comfortably inside the
/// 1–120 s reference-length validation at a natural reading pace.
public enum RecordingScript {
    public static let passage = """
        The old lighthouse keeper climbed the spiral stairs every evening, \
        counting each of the two hundred steps out loud. From the top, the \
        harbor lights blinked back at him like a code only sailors could \
        read. Some nights the fog rolled in so thick he couldn't see the \
        water at all, just the sound of waves against rock, patient and \
        unhurried, the way they'd been for a hundred years before he was \
        born and would be for a hundred after he was gone.
        """

    public static let tips = [
        "Record somewhere quiet — no fans, traffic, or echoey rooms.",
        "Keep a consistent distance from the mic, about a hand's width away.",
        "Speak at a natural pace — rushing flattens the performance.",
    ]

    public static func deliveryNote(for emotion: Emotion) -> String {
        switch emotion {
        case .flat: "Read in a flat monotone — minimal inflection, almost bored."
        case .neutral: "Read naturally, like you're explaining something to a friend."
        case .warm: "Read warmly and gently, like comforting someone."
        case .excited: "Read with real energy — like sharing good news."
        case .hype: "Read at maximum energy — like hyping up a crowd."
        }
    }
}
