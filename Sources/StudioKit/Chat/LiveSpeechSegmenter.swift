import EngineKit

/// Turns a streaming LLM reply into speakable sentences as the tokens arrive.
/// Feed raw deltas with `consume`; each call returns the sentences that just
/// became complete. `<think>` content never reaches the audio (deltas are
/// filtered through `stripThinking` incrementally), and the still-growing
/// trailing sentence is held back until it completes or the stream finishes.
public struct LiveSpeechSegmenter {
    private var rawAccum = ""
    /// The filtered (think-stripped) text already forwarded into `buffer`.
    private var seenFiltered = ""
    /// Unspoken filtered text, verbatim, waiting for a sentence boundary.
    private var buffer = ""
    /// True once the filtered stream stopped being a prefix-extension of what
    /// was already consumed (e.g. a mid-text think block shifted everything).
    /// From then on the live feed is unreliable and yields nothing; the caller
    /// decides whether to fall back to speaking the final text whole.
    public private(set) var derailed = false

    public init() {}

    /// Add a streamed delta; returns sentences now safe to synthesize.
    public mutating func consume(_ delta: String) -> [String] {
        guard !derailed else { return [] }
        rawAccum += delta
        let filtered = stripThinking(rawAccum)
        guard filtered.hasPrefix(seenFiltered) else {
            derailed = true
            return []
        }
        buffer += filtered.dropFirst(seenFiltered.count)
        seenFiltered = filtered
        let (complete, remainder) = SentenceSplitter.splitStreaming(buffer)
        buffer = remainder
        return complete
    }

    /// The stream finished with its authoritative text; returns the remaining
    /// unspoken sentences. Reasoning is stripped here too (the final text is
    /// raw when thinking is enabled; idempotent when already clean). Empty
    /// (and derailed) if the final text disagrees with what was already
    /// spoken — stopping beats double-speaking.
    public mutating func finish(finalText: String) -> [String] {
        guard !derailed else { return [] }
        let cleaned = stripThinking(finalText)
        guard cleaned.hasPrefix(seenFiltered) else {
            derailed = true
            return []
        }
        buffer += cleaned.dropFirst(seenFiltered.count)
        seenFiltered = cleaned
        let out = SentenceSplitter.split(buffer)
        buffer = ""
        return out
    }
}
