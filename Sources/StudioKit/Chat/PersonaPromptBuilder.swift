import Foundation

/// Composes the effective system prompt for chatting with a voice: the voice's
/// persona (or a stay-in-character default) plus TTS-friendly output rules —
/// everything the model says gets synthesized and spoken aloud.
public enum PersonaPromptBuilder {
    /// Appended to every chat system prompt so replies stay speakable.
    public static let speakingRules = """
    Your replies are spoken aloud by a text-to-speech voice. Reply only in \
    natural spoken prose: no markdown, no emoji, no bullet points, no headings, \
    no code blocks, no stage directions. Keep replies conversational and \
    reasonably brief.
    """

    public static func systemPrompt(voiceName: String, persona: Persona?) -> String {
        let custom = persona?.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let character = custom.isEmpty
            ? "You are \(voiceName). Stay in character as \(voiceName) throughout the conversation."
            : custom
        return character + "\n\n" + speakingRules
    }
}
