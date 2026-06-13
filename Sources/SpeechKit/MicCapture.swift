import AVFAudio
import Foundation

/// Microphone capture as an AsyncStream of Sendable chunks.
/// One instance = one capture session; create a fresh one per use.
@MainActor
public final class MicCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    public init() {}

    /// Starts the mic and returns the chunk stream. Throws if the input
    /// device is unavailable. Caller must call stop() when done.
    public func start() throws -> AsyncStream<AudioChunk> {
        guard continuation == nil else {
            throw SpeechError.engineUnavailable("capture already in progress")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw SpeechError.engineUnavailable("no audio input device")
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        // The tap fires on AVFAudio's private queue. It must be @Sendable so
        // it does NOT inherit this class's @MainActor isolation — the runtime
        // isolation check would trap on the first buffer. Capture the sample
        // rate as a plain Double, not the non-Sendable AVAudioFormat.
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(
                start: channel, count: Int(buffer.frameLength)))
            continuation.yield(AudioChunk(samples: samples,
                                          sampleRate: sampleRate))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            self.continuation = nil
            throw SpeechError.engineUnavailable(error.localizedDescription)
        }
        return stream
    }

    /// Stops the mic and finishes the stream (transcribers then emit finals).
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
