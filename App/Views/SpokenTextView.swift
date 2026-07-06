import StudioKit
import SwiftUI

/// Transcript text that karaoke-highlights the word currently being spoken.
/// The TTS gives no word-level alignment, so the active word is estimated from
/// playback progress proportional to character position within the chunk the
/// queue is voicing — approximate, but close enough to follow along.
struct SpokenTextView: View {
    let text: String
    let queue: ChatSpeechQueue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { _ in
            Text(highlighted())
                .textSelection(.enabled)
                .foregroundStyle(Brand.fg)
        }
    }

    private func highlighted() -> AttributedString {
        var attr = AttributedString(text)
        guard queue.isSpeaking, let chunk = queue.nowPlayingText,
              let (sentence, wordStart, wordEnd) = Self.activeWord(
                  in: chunk, progress: queue.playbackProgress),
              let sentenceRange = text.range(of: sentence)
        else { return attr }

        let base = text.distance(from: text.startIndex, to: sentenceRange.lowerBound)
        let lower = attr.index(attr.startIndex, offsetByCharacters: base + wordStart)
        let upper = attr.index(attr.startIndex, offsetByCharacters: base + wordEnd)
        attr[lower..<upper].backgroundColor = Brand.accent.opacity(0.35)
        return attr
    }

    /// Maps playback progress into (sentence, word bounds within it). The
    /// chunk may batch several sentences; sentences are located individually
    /// in the transcript because the batch's single-space joins may not match
    /// the original inter-sentence whitespace.
    static func activeWord(in chunk: String, progress: Double)
        -> (sentence: String, wordStart: Int, wordEnd: Int)?
    {
        let chars = Array(chunk)
        guard !chars.isEmpty else { return nil }
        var pos = min(chars.count - 1, Int(progress * Double(chars.count)))

        // Which sentence does pos land in? (Chunks are sentences re-joined
        // with single spaces, so cumulative lengths + 1 track positions.)
        let sentences = SentenceSplitter.split(chunk)
        guard !sentences.isEmpty else { return nil }
        var cursor = 0
        var active = sentences[sentences.count - 1]
        var offset = max(0, pos - max(0, chunk.count - active.count))
        for sentence in sentences {
            if pos <= cursor + sentence.count {
                active = sentence
                offset = max(0, pos - cursor)
                break
            }
            cursor += sentence.count + 1
        }

        // Word bounds around the offset within the active sentence.
        let sentenceChars = Array(active)
        guard !sentenceChars.isEmpty else { return nil }
        pos = min(offset, sentenceChars.count - 1)
        // If we landed on whitespace, nudge to the next word.
        while pos < sentenceChars.count - 1, sentenceChars[pos].isWhitespace { pos += 1 }
        var start = pos
        while start > 0, !sentenceChars[start - 1].isWhitespace { start -= 1 }
        var end = pos
        while end < sentenceChars.count, !sentenceChars[end].isWhitespace { end += 1 }
        guard start < end else { return nil }
        return (active, start, end)
    }
}
