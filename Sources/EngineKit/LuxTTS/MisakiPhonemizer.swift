// MisakiPhonemizer.swift
// EngineKit — license-clean G2P for LuxTTS.
//
// Replaces `EspeakProcessPhonemizer` (which shells out to a GPL-3.0 espeak-ng
// binary — undistributable via the App Store, and un-exec-able from inside the
// sandboxed .app anyway) with the Swift port of hexgrad's "misaki" G2P engine
// that ships inside our mlx-audio-swift fork (MIT licensed,
// TinyTrashLabs/mlx-audio-swift → MLXAudioTTS.MisakiTextProcessor /
// EnglishG2P). EngineKit already depends on MLXAudioTTS and
// `MisakiTextProcessor` is public, so this is plain cross-module reuse — no
// vendoring, no fork patch.
//
// ── The phoneme-format mismatch ───────────────────────────────────────────────
// LuxTTS's vocab (Resources/tokens.txt) is raw espeak-ng IPA, one Unicode
// scalar per token, with espeak's en-us conventions (length marks ː, r-colored
// ɚ, decomposed affricates d+ʒ / t+ʃ). Misaki emits a more compact custom
// alphabet:
//   * one capital letter per diphthong: A=eɪ I=aɪ O=oʊ W=aʊ Y=ɔɪ (Q=əʊ, GB)
//   * ligature affricates ʤ/ʧ for dʒ/tʃ
//   * no length marks at all (i vs espeak iː, ɑ vs ɑː, …)
//   * vowel+ɹ where espeak writes r-colored vowels (əɹ vs ɚ, ɜɹ vs ɜː)
//   * ᵊ for an optional/syllabic schwa
//   * a kitten-tts post-step inside EnglishG2P.phonemize rewrites flap ɾ → "T"
//     and glottal ʔ → "t". Capital T appears NOWHERE else in misaki's alphabet
//     (verified against us_gold/us_silver.json and the BART config's
//     phoneme_chars), so T→ɾ below is a lossless inverse. ʔ→t is NOT
//     invertible — the glottal-stop information is gone — but espeak-ng's
//     en-us voice virtually never emits ʔ either, so plain [t] is the correct
//     approximation, not a quality loss in practice.
//
// `remapToEspeakIPA` converts misaki output to the espeak-shaped IPA the
// LuxTTS checkpoint was trained on. The mapping was built by diffing misaki's
// us_gold dictionary against `espeak-ng -q --ipa -v en-us` for the same words;
// every rule below cites the word pairs that motivated it.
//
// Known deliberate approximations (verified against real espeak output):
//   * ɔ → ɔː always: espeak has rare short-ɔ words ("on" ˈɔn, "orange"
//     ˈɔɹɪndʒ) that gain a length mark here. Both spellings are in-vocab.
//   * word-final -i heuristic: FLEECE vs happY is not marked by misaki; we use
//     "final i in a word with ≥2 vowels is happY (short)" which gets
//     see/tea/happy/movie/city right but writes iː in a few mid-word happY
//     positions ("radio" ɹˈeɪdiːoʊ vs espeak ɹˈeɪdɪˌoʊ).
//   * misaki collapses NURSE to ɜɹ; espeak en-us writes ɜː with NO ɹ before a
//     consonant ("bird" bˈɜːd, "world" wˈɜːld) but ɜːɹ before a vowel
//     ("hurry" hˈɜːɹi). Both cases handled contextually below.

import Foundation
import MLXAudioTTS

/// PhonemizerProviding implementation backed by the misaki G2P engine from
/// mlx-audio-swift, with output remapped to espeak-ng-compatible IPA.
///
/// Use `MisakiPhonemizer.prepared()` — the underlying `MisakiTextProcessor`
/// needs its dictionaries + BART fallback checkpoint (≈9 MB, HuggingFace repo
/// beshkenadze/kitten-tts-g2p) resolved from cache or downloaded on first use.
public final class MisakiPhonemizer: PhonemizerProviding, @unchecked Sendable {
    private let processor: MisakiTextProcessor
    /// misaki's EnglishG2P mutates a shared NLTagger per call and
    /// `MisakiTextProcessor.process` does not serialize callers — do it here.
    private let lock = NSLock()

    private init(processor: MisakiTextProcessor) {
        self.processor = processor
    }

    /// Creates a phonemizer with its G2P resources resolved (downloading from
    /// HuggingFace into mlx-audio's cache on first ever use; afterwards this is
    /// a local directory check).
    public static func prepared() async throws -> MisakiPhonemizer {
        let processor = MisakiTextProcessor()
        try await processor.prepare()
        return MisakiPhonemizer(processor: processor)
    }

    public func phonemize(_ normalizedEnglishText: String) throws -> [String] {
        try PiperClauseAssembler.assemble(normalizedEnglishText) { clause in
            let raw: String
            lock.lock()
            defer { lock.unlock() }
            raw = try processor.process(text: clause, language: "en-us")
            return Self.remapToEspeakIPA(raw)
        }
    }

    // MARK: - misaki → espeak IPA remapping

    /// Vowel scalars as they appear AFTER the context-free pass (so including
    /// the e/a/o/ɔ introduced by diphthong expansion, and ɚ).
    private static let vowels = Set("aeiouæɑɒɔəɚɛɜɪʊʌᵻɐ")
    private static let stressMarks = Set("ˈˌ")

    /// Context-free single-symbol rewrites (pass 1).
    private static let simpleMap: [Character: String] = [
        // Diphthong capitals (misaki/kokoro convention → espeak en-us IPA):
        "A": "eɪ",   // FACE   ("today" tədˈA  → tədˈeɪ, espeak: tədˈeɪ)
        "I": "aɪ",   // PRICE  ("right" ɹˈIt   → ɹˈaɪt,  espeak: ɹˈaɪt)
        "O": "oʊ",   // GOAT   ("hello" həlˈO  → həlˈoʊ, espeak: həlˈoʊ)
        "W": "aʊ",   // MOUTH  ("how"   hˌW    → hˌaʊ,   espeak: hˈaʊ)
        "Y": "ɔɪ",   // CHOICE
        "Q": "əʊ",   // GB GOAT — only emitted by the en-gb lexicon; harmless here.
        // Ligature affricates → espeak's two-scalar spelling:
        "ʤ": "dʒ",   // "jump"   ʤˈʌmp → dʒˈʌmp (espeak: dʒˈʌmp)
        "ʧ": "tʃ",   // "church" ʧˈɜɹʧ → …tʃ    (espeak: tʃˈɜːtʃ)
        // Small/optional schwa → plain schwa ("orange" ˈɔɹᵊnʤ → …ən dʒ):
        "ᵊ": "ə",
        // Inverse of EnglishG2P's kitten-tts flap substitution (see header).
        // ɾ is in-vocab and exactly what espeak emits ("water" wˈɔːɾɚ).
        "T": "ɾ",
        // misaki's unknown-word marker — drop it rather than leak an OOV char.
        "❓": "",
    ]

    /// Converts one clause of misaki phoneme output to espeak-ng-shaped IPA.
    /// Words (space-separated chunks) are processed independently so
    /// word-boundary rules can't bleed across words.
    static func remapToEspeakIPA(_ misaki: String) -> String {
        let words = misaki
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { remapWord(String($0)) }
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    private static func remapWord(_ word: String) -> String {
        // Pass 1: context-free symbol rewrites.
        var expanded = ""
        expanded.reserveCapacity(word.count + 8)
        for ch in word {
            if let replacement = simpleMap[ch] {
                expanded += replacement
            } else {
                expanded.append(ch)
            }
        }

        let chars = Array(expanded)
        let vowelCount = chars.filter { vowels.contains($0) }.count

        // The next non-stress-mark character after index i, if any (stress
        // marks sit between a consonant and its vowel: "əɹˈAnʤ").
        func nextSound(after i: Int) -> Character? {
            var j = i + 1
            while j < chars.count, stressMarks.contains(chars[j]) { j += 1 }
            return j < chars.count ? chars[j] : nil
        }

        // Pass 2: contextual rules (length marks + r-colored vowels).
        var out = ""
        out.reserveCapacity(chars.count + 8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "ɜ":
                // NURSE. espeak en-us: ɜː before a consonant/word-end (the ɹ
                // is absorbed: "bird" bˈɜːd, "early" ˈɜːli, "were" wˈɜː) but
                // ɜːɹ when a vowel follows ("hurry" hˈɜːɹi, "courage"
                // kˈɜːɹɪdʒ).
                if next == "ɹ" {
                    if let after = nextSound(after: i + 1), vowels.contains(after) {
                        out += "ɜːɹ"
                    } else {
                        out += "ɜː"
                    }
                    i += 2
                    continue
                }
                out += "ɜː"
            case "ə":
                // lettER. misaki writes əɹ; espeak en-us writes ɚ before a
                // consonant/word-end ("father" fˈɑːðɚ, "understand"
                // ˌʌndɚstˈænd) and ɚɹ before a vowel ("around" ɚɹˈaʊnd,
                // "error" ˈɛɹɚ).
                if next == "ɹ" {
                    if let after = nextSound(after: i + 1), vowels.contains(after) {
                        out += "ɚɹ"
                    } else {
                        out += "ɚ"
                    }
                    i += 2
                    continue
                }
                out.append(c)
            case "ɑ":
                // espeak en-us always length-marks PALM/LOT: "hot" hˈɑːt,
                // "are" ˈɑːɹ.
                out += "ɑː"
            case "ɔ":
                // THOUGHT/NORTH: "all" ˈɔːl, "north" nˈɔːɹθ. Skip when part of
                // a CHOICE ɔɪ sequence (reintroduced by the Y expansion above).
                out += (next == "ɪ") ? "ɔ" : "ɔː"
            case "u":
                // GOOSE is always long in espeak en-us: "do" dˈuː, "you" juː,
                // "beautiful" bjˈuːɾifəl.
                out += "uː"
            case "i":
                // FLEECE vs happY (misaki doesn't distinguish): final i in a
                // multi-vowel word is happY and stays short ("happy" hˈæpi,
                // "movie" mˈuːvi); before ə/ɚ it stays short ("furious"
                // fjˈʊɹiəs); otherwise FLEECE iː ("see" sˈiː, "tea" tˈiː,
                // "being" bˈiːɪŋ).
                let isFinal = (i == chars.count - 1)
                if (isFinal && vowelCount >= 2) || next == "ə" || next == "ɚ" {
                    out.append(c)
                } else {
                    out += "iː"
                }
            default:
                out.append(c)
            }
            i += 1
        }
        return out
    }
}
