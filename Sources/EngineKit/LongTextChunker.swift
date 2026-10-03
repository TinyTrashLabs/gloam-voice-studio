import Foundation

/// Splits a long line into pieces a capped autoregressive model can finish.
///
/// Breeze stops at 750 codec frames — 12.5 frames/s, so 60 s of speech — and
/// the Studio bench sends a whole line at once. Past the cap the take simply
/// ends mid-sentence with no error. Qwen shares the codec but allows 4096
/// frames, which is why this never came up before.
///
/// Pieces are whole sentences packed greedily up to `maxSeconds` of
/// ESTIMATED speech, so they stay well under the cap with room for a slow
/// Direction. A single sentence that is still too long falls back to word
/// boundaries (or characters, for unspaced Chinese). Lives in EngineKit
/// because StudioKit's SentenceSplitter is out of reach from here, and this
/// only needs boundaries, not abbreviation handling — a split after "Dr." is
/// a slightly early breath, not a lost word.
public enum LongTextChunker {
    /// Rough speaking rates: ~15 Latin characters/s, ~4.5 CJK characters/s.
    public static func estimatedSeconds(_ text: String) -> Double {
        var latin = 0, cjk = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) { latin += 1 }
        }
        return Double(latin) / 15 + Double(cjk) / 4.5
    }

    public static func chunks(_ text: String, maxSeconds: Double = 40) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard estimatedSeconds(trimmed) > maxSeconds else { return [trimmed] }

        var out: [String] = []
        var current = ""
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            current = ""
        }
        for sentence in sentences(trimmed) {
            if estimatedSeconds(sentence) > maxSeconds {
                flush()
                out.append(contentsOf: splitOversized(sentence, maxSeconds: maxSeconds))
                continue
            }
            if !current.isEmpty && estimatedSeconds(current + sentence) > maxSeconds { flush() }
            current += sentence
        }
        flush()
        return out
    }

    /// Sentences with their terminator and trailing space kept attached.
    static func sentences(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "\n"]
        var result: [String] = []
        var current = ""
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            current.append(c)
            guard terminators.contains(c) else { continue }
            // Keep a run like "?!" or "..." and the following spaces together.
            while let next = chars.first, terminators.contains(next) || next == " " {
                current.append(next); chars = chars.dropFirst()
            }
            result.append(current); current = ""
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func splitOversized(_ sentence: String, maxSeconds: Double) -> [String] {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Unspaced (Chinese) text arrives as one "word": fall back to characters.
        let units = words.count > 1 ? words.map { $0 + " " } : sentence.map(String.init)
        var out: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty && estimatedSeconds(current + unit) > maxSeconds {
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
            current += unit
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
        default: false
        }
    }
}
