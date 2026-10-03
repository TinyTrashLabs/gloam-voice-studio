import Foundation

/// Why a render stopped.
public enum QwenStopReason: String, Sendable {
    /// The talker emitted its end-of-speech token.
    case eos
    /// The frame cap (6 frames per text token, at least 75, at most 4096) was reached.
    case maxTokens
    /// `cancelled()` returned true; `QwenRender.samples` is empty.
    case cancelled
    /// The line ended in 1.5 s of silence, which was cut (the order render_onnx.py uses).
    case trailingSilence
    /// The talker's 1024-row KV window filled before the end-of-speech token, so the line is cut short
    /// (the audio is a truncated line). Split the text first: see `QwenANEEngine.maxFrames(text:voice:)`.
    case contextFull
}

public enum QwenANEError: Error, LocalizedError {
    case invalid(String)
    /// The Neural Engine produced NaN/Inf (or a code outside the codebook). The line is abandoned, the
    /// KV state is reset, and the engine is usable for the next line.
    case nonFinite(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return "QwenANE: \(m)"
        case .nonFinite(let m): return "QwenANE: non-finite output (\(m))"
        }
    }
}

/// Per-line wall-clock timings, in seconds.
public struct QwenTimings: Sendable {
    /// Prompt build: text projection, tokenizer, ICL rows.
    public var prompt: Double
    /// Talker prefill plus the first decode step.
    public var prefill: Double
    /// Talker + code predictor loop (`generate` wall; with the vocoder overlapped it contains no vocoder wait).
    public var loop: Double
    /// Vocoder busy time: head + upsamplers (+ reference priming on a voice's first line), wherever it ran.
    /// When `overlapVocoder` is on this runs beside `loop`, so it is not added to the wall time.
    public var vocoder: Double
    /// Time `finish()` blocked on the vocoder queue after the last frame (0 inline).
    public var vocoderWait: Double
    /// Whole `render` call.
    public var total: Double
}

/// The result of one rendered line.
public struct QwenRender: Sendable {
    /// Mono float samples at `sampleRate` (frames x 1920). Empty when cancelled.
    public var samples: [Float]
    public var sampleRate: Int
    /// Audio frames kept (80 ms each), after any trailing-silence cut.
    public var frames: Int
    /// The codec codes for the kept frames, frame-major (frames x 16).
    public var codes: [Int64]
    public var stopReason: QwenStopReason
    public var timings: QwenTimings
    /// Silence in the vocoder output, before `Options.capPauses` ran (`.empty` when cancelled).
    public var silenceBefore: SilenceReport = .empty
    /// Silence in `samples` as returned (equals `silenceBefore` when capping is off or nothing was cut).
    public var silence: SilenceReport = .empty
    /// Internal pauses shortened by `Options.capPauses`.
    public var pausesCapped: Int = 0
    /// Seconds of audio. `frames` and `codes` describe the uncapped render; `samples` is capped.
    public var audioSeconds: Double { Double(samples.count) / Double(sampleRate) }
}

@available(iOS 18.0, macOS 15.0, *)
extension QwenANEEngine {
    public struct Options: Sendable {
        /// Decode vocoder chunks on a serial queue beside the talker loop (same samples, less wall time).
        public var overlapVocoder = true
        /// Shorten dead air in the finished line (see `QwenSilence.cap`): internal pauses over 0.7 s down
        /// to 0.45 s, leading silence to 0.05 s, trailing to 0.1 s.
        public var capPauses = true
        public init(overlapVocoder: Bool = true, capPauses: Bool = true) {
            self.overlapVocoder = overlapVocoder; self.capPauses = capPauses
        }
    }
}

/// Text to speech with Qwen3-TTS 0.6B on the Neural Engine: talker + code predictor and the
/// vocoder upsampler run as Core ML models, the rest (text projection, vocoder head) on the CPU.
/// No MLX, no ONNX Runtime. See the README next to this file for the model directory layout.
///
/// One engine renders one line at a time: `render` is serialised by an internal lock, so a second
/// caller waits. Create one engine per process and share it; building it loads about 1.3 GB of
/// models and warms the vocoder, which takes seconds. `render` blocks for the whole line (about
/// real time), so call it from a background queue.
@available(iOS 18.0, macOS 15.0, *)
public final class QwenANEEngine: @unchecked Sendable {
    private let host: HostTables
    let talker: ANETalkerEngine
    private let vocoder: ANEVocoder
    private let lock = NSLock()
    /// The directory the engine was loaded from; `loadVoice(named:)` reads `voices/<name>` under it.
    public let modelsDirectory: URL
    /// Frames (80 ms each) the talker can generate for `text` in `voice` before its KV window fills: the
    /// smaller of the 6-frames-per-token cap and the window left after the prompt (reference + text).
    /// A line that hits the window ends with `.contextFull`; hosts split text so this stays above the
    /// frames the line needs. Throws for a voice that fails validation.
    public func maxFrames(text: String, voice: QwenVoiceFiles) throws -> Int {
        try QwenVoiceFiles.validate(refCodes: voice.refCodes)
        let p = buildICLPrompt(host: host, voice: voice, text: text)
        return min(effectiveMaxTokens(p.nTextTokens), ANETalkerEngine.windowFrames(promptRows: p.T))
    }

    /// Drops every cache that can be rebuilt: the vocoder's primed per-voice states (the next line of a
    /// voice re-primes, about a second). Call on a memory warning.
    public func dropCaches() {
        lock.lock(); defer { lock.unlock() }
        vocoder.dropCaches()
    }

    /// Read at the start of each `render`; set between renders.
    public var options = Options()

    /// Loads host tables, the vocoder head and the compiled Core ML models (`.mlmodelc`).
    /// The vocoder loads first: the Core ML models before anything that maps big files.
    public init(modelsDirectory: URL) throws {
        self.modelsDirectory = modelsDirectory
        host = try HostTables(dir: modelsDirectory.appendingPathComponent("host").path)
        vocoder = try ANEVocoder(modelsDirectory: modelsDirectory)
        talker = try ANETalkerEngine(coreMLDirectory: modelsDirectory.appendingPathComponent("coreml"), host: host)
    }

    /// Reads `voices/<name>/{voice.json, ref_codes.npy, spk_embed.npy}` from the models directory.
    public func loadVoice(named name: String) throws -> QwenVoiceFiles {
        try QwenVoiceFiles(directory: modelsDirectory.appendingPathComponent("voices").appendingPathComponent(name))
    }

    /// Renders one line in `voice`.
    ///
    /// - Parameters:
    ///   - seed: sampler seed. The same seed draws numpy's `default_rng(seed)` stream, which makes
    ///     a render reproducible and comparable to the Python reference. `nil` picks a random one.
    ///   - maxFrames: optional cap on generated frames (80 ms each), below the built-in cap.
    ///   - cancelled: polled once per frame; return true to stop. The render then returns no samples.
    ///   - pace: called between stages and after every frame, on the rendering thread. A host app
    ///     can sleep in it to hold a duty cycle (thermal / battery); a sleep adds directly to wall time.
    public func render(text: String, voice: QwenVoiceFiles, seed: UInt64? = nil, maxFrames: Int? = nil,
                       cancelled: () -> Bool = { false }, pace: () -> Void = {}) throws -> QwenRender {
        lock.lock(); defer { lock.unlock() }
        try QwenVoiceFiles.validate(refCodes: voice.refCodes)
        guard voice.spkEmbedding.count == HostTables.H else {
            throw QwenANEError.invalid("spkEmbedding must have \(HostTables.H) values")
        }
        var sampler = Sampler(vocab: host.cfg.vocab, eos: host.cfg.codecEos, seed: seed ?? UInt64.random(in: 0...UInt64.max))
        let t0 = Date()
        let prompt = buildICLPrompt(host: host, voice: voice, text: text)
        let promptS = Date().timeIntervalSince(t0)
        pace()
        let voc = vocoder
        voc.overlap = options.overlapVocoder
        let overlapped = voc.overlap
        voc.resetStats(); voc.begin(context: voice.referenceFrames)
        let g: GenResult
        do {
            g = try talker.generate(prompt: prompt, sampler: &sampler, eos: host.cfg.codecEos, maxNew: maxFrames,
                                    cancelled: cancelled, onFrame: { _, codes in try voc.push(frame: codes); pace() })
        } catch { voc.drain(); throw error }
        var n = g.frames
        func result(_ wav: [Float], _ stop: QwenStopReason, _ codes: [Int64]) -> QwenRender {
            QwenRender(samples: wav, sampleRate: sampleRate, frames: n, codes: codes, stopReason: stop,
                       timings: QwenTimings(prompt: promptS, prefill: g.prefillWall,
                                            loop: overlapped ? g.loopWall : max(0, g.loopWall - voc.wall),
                                            vocoder: voc.wall, vocoderWait: voc.waitWall, total: Date().timeIntervalSince(t0)))
        }
        guard n > 0, g.stop != .cancelled else { voc.drain(); n = 0; return result([], g.stop, []) }
        pace()
        var wav: [Float]
        do { wav = try voc.finish() } catch { voc.drain(); throw error }   // flushes the partial last chunk, waits for the queue
        pace()
        var stop = g.stop
        var codes = g.codes
        let cut = trailingSilenceCut(wav, frames: n)
        if cut < n {
            n = cut; wav = Array(wav[0..<(cut * samplesPerFrame)]); codes = Array(codes[0..<(cut * 16)])
            if stop != .contextFull { stop = .trailingSilence }
        }
        var out = result(wav, stop, codes)
        out.silenceBefore = QwenSilence.analyze(samples: wav, sampleRate: sampleRate)
        out.silence = out.silenceBefore
        if options.capPauses {
            let c = QwenSilence.cap(samples: wav, sampleRate: sampleRate)
            if c.samples.count != wav.count {
                out.samples = c.samples; out.pausesCapped = c.pausesCapped
                out.silence = QwenSilence.analyze(samples: c.samples, sampleRate: sampleRate)
            }
        }
        return out
    }
}
