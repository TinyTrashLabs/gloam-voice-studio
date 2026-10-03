import Foundation

/// Why a render stopped.
public enum QwenStopReason: String, Sendable {
    /// The talker emitted its end-of-speech token.
    case eos
    /// The frame cap (6 frames per text token, at least 75, at most 4096, and the KV window) was reached.
    case maxTokens
    /// `cancelled()` returned true; `QwenRender.samples` is empty.
    case cancelled
    /// The line ended in 1.5 s of silence, which was cut (the order render_onnx.py uses).
    case trailingSilence
}

public enum QwenANEError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self { case .invalid(let m): return "QwenANE: \(m)" }
    }
}

/// Per-line wall-clock timings, in seconds.
public struct QwenTimings: Sendable {
    /// Prompt build: text projection, tokenizer, ICL rows.
    public var prompt: Double
    /// Talker prefill plus the first decode step.
    public var prefill: Double
    /// Talker + code predictor loop, vocoder time excluded.
    public var loop: Double
    /// Vocoder wall time inside the line (head + upsamplers; reference priming on a voice's first line).
    public var vocoder: Double
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
    /// Seconds of audio.
    public var audioSeconds: Double { Double(samples.count) / Double(sampleRate) }
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
        guard voice.refCodes.count == 16, let t = voice.refCodes.first?.count, t > 0,
              voice.refCodes.allSatisfy({ $0.count == t }) else {
            throw QwenANEError.invalid("refCodes must be 16 rows of equal, non-zero length")
        }
        guard voice.spkEmbedding.count == HostTables.H else {
            throw QwenANEError.invalid("spkEmbedding must have \(HostTables.H) values")
        }
        var sampler = Sampler(vocab: host.cfg.vocab, eos: host.cfg.codecEos, seed: seed ?? UInt64.random(in: 0...UInt64.max))
        let t0 = Date()
        let prompt = buildICLPrompt(host: host, voice: voice, text: text)
        let promptS = Date().timeIntervalSince(t0)
        pace()
        vocoder.resetStats(); vocoder.begin(context: voice.referenceFrames)
        let voc = vocoder
        let g = try talker.generate(prompt: prompt, sampler: &sampler, eos: host.cfg.codecEos, maxNew: maxFrames,
                                    cancelled: cancelled, onFrame: { _, codes in try voc.push(frame: codes); pace() })
        var n = g.frames
        func result(_ wav: [Float], _ stop: QwenStopReason, _ codes: [Int64]) -> QwenRender {
            QwenRender(samples: wav, sampleRate: sampleRate, frames: n, codes: codes, stopReason: stop,
                       timings: QwenTimings(prompt: promptS, prefill: g.prefillWall, loop: max(0, g.loopWall - voc.wall),
                                            vocoder: voc.wall, total: Date().timeIntervalSince(t0)))
        }
        guard n > 0, g.stop != .cancelled else { n = 0; return result([], g.stop, []) }
        pace()
        var wav = try voc.finish()                  // flushes the partial last chunk
        pace()
        var stop = g.stop
        var codes = g.codes
        let cut = trailingSilenceCut(wav, frames: n)
        if cut < n {
            n = cut; wav = Array(wav[0..<(cut * samplesPerFrame)]); codes = Array(codes[0..<(cut * 16)])
            stop = .trailingSilence
        }
        return result(wav, stop, codes)
    }
}
