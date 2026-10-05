import EngineKit

/// How chat hands a reply's sentences to the voice.
///
/// Two shapes, by backend:
/// - **Batched** (GPU clone backends): every call pays a fixed cost of seconds (reference processing), and
///   the whole render must finish before anything plays. The first sentence goes alone for the fastest
///   first audio; after that, everything that queued up while it rendered goes as ONE call, capped at
///   `batchedMaxChars`, so the fixed cost is paid once per batch rather than once per sentence.
/// - **Streamed** (`qwen3-0.6b-ane`): audio plays as the render makes it, from its first short vocoder
///   chunk, and a call's fixed cost is small (prefix and voice caches). A batch would only delay the next
///   sentence's first sound until the batch's text was all known, so each sentence goes as soon as it is
///   complete; only sentences already waiting are joined, up to `streamedMaxChars`.
public enum ChatSpeechScheduling {
    public static let batchedMaxChars = 280
    public static let streamedMaxChars = 120
    /// The streamed render's first vocoder chunk, in 80 ms frames: 4 ≈ 0.32 s of audio, out about half a
    /// second sooner than a whole 12-frame chunk. The schedule grows back to whole chunks after it.
    public static let firstChunkFrames = 4

    /// Whether chat speech on `backend` streams into playback chunk by chunk.
    public static func streams(_ backend: BackendID) -> Bool {
        backend.speechFamily == .neuralEngine
    }

    /// Takes the next segment to render off the front of `queue`: its first sentence, then any queued
    /// sentences that still fit the cap. nil when the queue is empty.
    public static func nextSegment(from queue: inout [String], streaming: Bool) -> String? {
        guard !queue.isEmpty else { return nil }
        let cap = streaming ? streamedMaxChars : batchedMaxChars
        var segment = queue.removeFirst()
        while let next = queue.first, segment.count + next.count < cap {
            queue.removeFirst()
            segment += " " + next
        }
        return segment
    }
}

/// Edge fades for audio that arrives in pieces: fades the START of the first piece in and the END of the
/// last piece out, and nothing in between, so a streamed render played back to back has no dip at its chunk
/// joins. The end is not known until `finish`, so the last `milliseconds` of audio are held back until then.
///
/// The output joined is exactly `AudioAssembler.fadeEdges` of the input joined (for input longer than two
/// fades).
public struct StreamEdgeFader: Sendable {
    public let fadeSamples: Int
    private var held: [Float] = []
    private var fadedIn = 0

    public init(sampleRate: Int, milliseconds: Double = 8) {
        fadeSamples = max(0, Int(Double(sampleRate) * milliseconds / 1000))
    }

    /// Hands back the audio now safe to play (everything but the held-back tail).
    public mutating func push(_ samples: [Float]) -> [Float] {
        held += samples
        guard held.count > fadeSamples else { return [] }
        var out = Array(held[..<(held.count - fadeSamples)])
        held.removeFirst(out.count)
        // The fade-in runs over the first `fadeSamples` samples ever released.
        var i = 0
        while fadedIn < fadeSamples, i < out.count {
            out[i] *= Float(fadedIn) / Float(fadeSamples)
            fadedIn += 1; i += 1
        }
        return out
    }

    /// The held-back tail, faded out. A stream shorter than two fades is faded whole, like `fadeEdges`.
    public mutating func finish() -> [Float] {
        defer { held = [] }
        guard fadeSamples > 0 else { return held }
        if fadedIn == 0 {
            // Nothing released yet: the whole (short) stream is here.
            return AudioAssembler.fadeEdges(held, sampleRate: 1000,
                                            milliseconds: Double(fadeSamples))
        }
        var out = held
        let n = out.count
        for i in 0 ..< n {
            // Mirrors fadeEdges: the last sample gets gain 0, the one before 1/fade, …
            out[n - 1 - i] *= Float(i) / Float(fadeSamples)
        }
        return out
    }
}

/// One streamed segment played as it renders.
public enum StreamedSegmentPump {
    public struct Result: Sendable {
        /// Everything rendered, gain applied, without the playback fades (what a saved take keeps).
        public var samples: [Float]
        public var sampleRate: Int?
        /// The consumer stopped early (Stop, interruption): the samples are what had arrived by then.
        public var cancelled: Bool
    }

    /// Consumes `chunks`, applies the voice's `gainDb` and hands each piece to `deliver` in order as it
    /// arrives, with fades only at the segment's start and end. Stops as soon as the calling task is
    /// cancelled; leaving the loop ends the chunk stream, which stops the render behind it. Errors from the
    /// render propagate; cancellation does not throw.
    public static func run(_ chunks: AsyncThrowingStream<SynthesisChunk, Error>, gainDb: Double,
                           deliver: @MainActor @Sendable ([Float], Int) -> Void) async throws -> Result {
        var result = Result(samples: [], sampleRate: nil, cancelled: false)
        var fader: StreamEdgeFader?
        do {
            for try await chunk in chunks {
                if Task.isCancelled { break }
                guard !chunk.samples.isEmpty else { continue }
                let rate = chunk.sampleRate
                result.sampleRate = rate
                let gained = AudioAssembler.applyGain(floats: chunk.samples, db: gainDb)
                result.samples += gained
                if fader == nil { fader = StreamEdgeFader(sampleRate: rate) }
                let ready = fader!.push(gained)
                if !ready.isEmpty { await deliver(ready, rate) }
            }
        } catch {
            if !(error is CancellationError) && !Task.isCancelled { throw error }
        }
        if Task.isCancelled {
            result.cancelled = true
            return result
        }
        if let rate = result.sampleRate, var f = fader {
            let tail = f.finish()
            if !tail.isEmpty { await deliver(tail, rate) }
        }
        return result
    }
}
