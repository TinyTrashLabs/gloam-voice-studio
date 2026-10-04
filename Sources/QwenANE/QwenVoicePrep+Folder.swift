// QwenVoicePrep+Folder.swift
// QwenANE — make a voice's `engines/qwen3-0.6b/` folder complete, once, at prep time.
//
// The one function both apps call (macOS Studio through EngineKit, the iOS
// radio app directly). A master of any length goes in; what comes out on disk
// is the engine's own folder: when the master fits the speech encoder, the
// codes + embedding of the master; when it does not, a SECTION of it
// (`ref.wav`, its exact transcript, the span it covers and the master's
// hash) with the codes + embedding computed from that section. A caller that
// only renders reads the folder and never cuts anything. Nothing here picks
// at render time: a folder that is already complete for this master is
// returned as it is (no encoders, no recognizer).
//
// MLX-free; the recognizer is a closure the host supplies, so this target
// links no Speech framework.

import Foundation
import GVoiceKit

extension QwenVoicePrep {
    public static let sectionMember = "engines/qwen3-0.6b/ref.wav"

    /// A section's audio path: `ref.wav`, or a pack's suffixed `ref-<key>.wav` for a take (import keeps the
    /// pack's name in voice.json while installing the file under its plain name).
    static func isSectionAudio(_ path: String) -> Bool {
        path == sectionMember || (path.hasPrefix("engines/qwen3-0.6b/ref-") && path.hasSuffix(".wav"))
    }

    /// The voice's `engines/qwen3-0.6b/` files, or nil when absent or unusable.
    public static func storedFolder(in voiceDir: URL) -> QwenEngineFiles? {
        let dir = voiceDir.appendingPathComponent(QwenEngineFiles.directory, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var files: [String: Data] = [:]
        for n in names {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)), d.count <= QwenEngineFiles.maxNPYBytes else { continue }
            files[n] = d
        }
        return try? QwenEngineFiles.decode(files: files)
    }

    /// Writes a prepared voice into the folder. voice.json is the commit marker: gone first, written last.
    public static func writeFolder(_ payload: QwenEngineFiles, in voiceDir: URL) {
        guard let files = try? payload.files() else { return }
        let dir = voiceDir.appendingPathComponent(QwenEngineFiles.directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(QwenEngineFiles.voiceFile))
        for (name, data) in files where name != QwenEngineFiles.voiceFile {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        if let voice = files[QwenEngineFiles.voiceFile] {
            try? voice.write(to: dir.appendingPathComponent(QwenEngineFiles.voiceFile), options: .atomic)
        }
    }

    /// Prepares `voiceDir`'s qwen3-0.6b folder from its master. `masterWAV` is the voice's `source/ref.wav`
    /// (mono 24 kHz, through ReferenceStandard); `transcript` is the master's. `storeFolder` false prepares without
    /// persisting. A take (language reference, emotion) stores its own folder like the base; export
    /// suffixes the member names (GVoice.export). `transcribe` returns the words of a WAV (on-device recognition) or nil; without it the
    /// section's transcript is the master's, sliced to the section at sentence ends.
    @discardableResult
    public static func prepareEngineFolder(
        voiceDir: URL, masterWAV: Data, transcript: String, modelsDirectory: URL, cacheDirectory: URL,
        storeFolder: Bool? = nil,
        transcribe: (@Sendable (Data) async -> String?)? = nil
    ) async throws -> Prepared {
        try await prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: masterWAV, transcript: transcript, cacheDirectory: cacheDirectory,
            storeFolder: storeFolder, transcribe: transcribe,
            limitSamples: sectionLimitSamples(modelsDirectory: modelsDirectory),
            encode: { try prepare(referenceWAV: $0, transcript: $1, modelsDirectory: modelsDirectory) })
    }

    /// The sentence-end cut whose audio says exactly its transcript. `endAtSentence` places the cut by a
    /// character clock, which can land a pause or two late: Bad Bunny's Spanish section kept "Yo creo que"
    /// after a transcript ending "en especifico.", and that mismatch at the end of the reference (Qwen continues
    /// it) is what made one Spanish part in four come out as silence or "no, no, no". Each candidate cut
    /// (`ReferenceSection.sentenceEndCandidates`, the guess first) is transcribed and the one whose words are
    /// closest to its transcript (`wordDistance`) is kept, an exact match ending the search. Without a
    /// transcription (no recogniser for the language) the guess stands.
    static func verifiedSentenceEnd(cut: [Float], words: String, guess: (samples: [Float], text: String),
                                    transcribe: @Sendable (Data) async -> String?) async -> (samples: [Float], text: String) {
        var candidates = [guess]
        for c in ReferenceSection.sentenceEndCandidates(samples: cut, text: words, sampleRate: sampleRate)
        where !(c.samples.count == guess.samples.count && c.text == guess.text) { candidates.append(c) }
        var best: (cut: (samples: [Float], text: String), distance: Int)? = nil
        for c in candidates {
            guard let heard = await transcribe(ReferenceSection.wavData(c.samples, sampleRate: sampleRate)) else {
                if best == nil { return guess } else { continue }
            }
            let d = ReferenceSection.wordDistance(heard: heard, text: c.text)
            // fewer mismatched words wins; on a tie, the longer cut (more of the voice)
            if best == nil || d < best!.distance || (d == best!.distance && c.samples.count > best!.cut.samples.count) {
                best = (c, d)
            }
            if d == 0 { break }
        }
        return best?.cut ?? guess
    }

    /// Test seam: the encoder's input length and the encoders themselves are injected.
    static func prepareEngineFolder(
        voiceDir: URL, masterWAV: Data, transcript: String, cacheDirectory: URL,
        storeFolder: Bool? = nil,
        transcribe: (@Sendable (Data) async -> String?)? = nil,
        limitSamples limit: Int,
        encode: (Data, String) throws -> QwenVoiceFiles
    ) async throws -> Prepared {
        let store = storeFolder ?? true
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let masterSha = sha256Hex(masterWAV)
        let all = try samples(of: masterWAV)
        let trimmedCount = ReferenceTail.end(of: all, sampleRate: sampleRate)
        let existing = storedFolder(in: voiceDir)

        func prepare(_ wav: Data, _ words: String) throws -> Prepared {
            try prepared(fromPack: existing, referenceWAV: wav, transcript: words,
                         cacheDirectory: cacheDirectory, encode: encode)
        }

        // The master fits the encoder: no section.
        if trimmedCount <= limit {
            let r = try prepare(masterWAV, text)
            if r.origin != .pack, store { writeFolder(try r.enginePayload(), in: voiceDir) }
            return r
        }

        // A stored section for THIS master, intact: read it, cut nothing.
        let sectionURL = voiceDir.appendingPathComponent(sectionMember)
        if let e = existing, isSectionAudio(e.derivedFrom.audio),
           let start = e.derivedFrom.startSeconds, let end = e.derivedFrom.endSeconds,
           e.derivedFrom.sourceSha256 == nil || e.derivedFrom.sourceSha256 == masterSha,
           let wav = try? Data(contentsOf: sectionURL), sha256Hex(wav) == e.derivedFrom.sha256 {
            let r = try prepare(wav, e.text)
            if r.origin != .pack, store {
                writeFolder(try r.enginePayload(audio: sectionMember, window: (start, end), sourceSHA256: masterSha), in: voiceDir)
            }
            return r
        }

        // Choose it now (prep time), store it, and encode from it.
        let maxSeconds = min(Double(limit) / Double(sampleRate), 30)
        let cut = ReferenceSection.cut(samples: all, sampleRate: sampleRate, maxSeconds: maxSeconds)
        // The words of the energy cut, then both cut back to a sentence end: a reference that stops
        // mid-sentence makes Qwen continue it.
        let cutWAV = ReferenceSection.wavData(cut.samples, sampleRate: sampleRate)
        let cutSecs = Double(cut.samples.count) / Double(sampleRate)
        let heard = await transcribe?(cutWAV)
        let cutWords = ReferenceSection.text(heard: heard, transcript: text, cutSeconds: cutSecs,
                                             start: cut.start, count: cut.samples.count, total: all.count).text
        var ended = ReferenceSection.endAtSentence(samples: cut.samples, text: cutWords, sampleRate: sampleRate)
        if let transcribe, ended.samples.count < cut.samples.count {
            ended = await verifiedSentenceEnd(cut: cut.samples, words: cutWords, guess: ended, transcribe: transcribe)
        }
        let sectionWAV = ReferenceSection.wavData(ended.samples, sampleRate: sampleRate)
        let cutSeconds = Double(ended.samples.count) / Double(sampleRate)
        let words = ended.text
        let start = Double(cut.start) / Double(sampleRate)
        let span = (start: start, end: start + cutSeconds)
        if store {
            try? FileManager.default.createDirectory(at: sectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? sectionWAV.write(to: sectionURL, options: .atomic)
        }
        let r = try prepare(sectionWAV, words)
        if store {
            writeFolder(try r.enginePayload(audio: sectionMember, window: span, sourceSHA256: masterSha), in: voiceDir)
        }
        return r
    }
}
