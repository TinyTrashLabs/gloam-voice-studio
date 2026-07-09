import Foundation

/// One instruction template per prompt-like field in the app, used by
/// AppModel.expand(_:kind:) to turn a short, terse field value into a fuller
/// one via the user's chosen local chat LLM.
public enum PromptExpansionKind: Sendable {
    case voiceDescription
    case direction
    case persona
    case greeting

    /// Used in the Expand button's tooltip: "expand this into a fuller ___".
    public var noun: String {
        switch self {
        case .voiceDescription: "voice description"
        case .direction: "performance direction"
        case .persona: "character description"
        case .greeting: "greeting"
        }
    }

    public var instruction: String {
        switch self {
        case .voiceDescription:
            """
            You help voice actors write vivid, technically useful text-to-speech \
            voice-design descriptions. Given a short, terse description of a \
            voice, rewrite it into 2-4 sentences that describe: the speaker's \
            apparent age and gender, vocal texture (e.g. raspy, smooth, breathy), \
            pitch range, pacing/rhythm, and emotional tone. Keep it concrete and \
            evocative, avoid vague adjectives alone, and never invent details the \
            user didn't imply. Reply with ONLY the rewritten description, no \
            preamble, no quotes.
            """
        case .direction:
            """
            You help voice actors write clear text-to-speech performance \
            direction — instructions for how a line should be delivered \
            (pacing, emotion, emphasis, energy), not a description of the voice \
            itself. Given the user's short direction, rewrite it into 1-3 \
            concise sentences describing tone, pacing, and emotional delivery \
            for this reading. Reply with ONLY the rewritten direction, no \
            preamble, no quotes.
            """
        case .persona:
            """
            You help write system prompts that define a chat character's \
            personality for a voice assistant. Given the user's short character \
            sketch, rewrite it into a clear, well-structured system-prompt \
            paragraph covering: who this character is, their personality \
            traits, how they speak (tone, vocabulary, quirks), and any relevant \
            backstory or context — written as direct instructions to the \
            character ("You are..."), 3-6 sentences. Reply with ONLY the \
            rewritten system prompt, no preamble, no quotes.
            """
        case .greeting:
            """
            You help write short, in-character opening greetings for a voice \
            assistant's first message in a new conversation. Given the user's \
            rough idea, rewrite it into ONE natural-sounding spoken greeting \
            (1-2 sentences) that fits the character. Reply with ONLY the \
            greeting text, no preamble, no quotes, no stage directions.
            """
        }
    }
}
