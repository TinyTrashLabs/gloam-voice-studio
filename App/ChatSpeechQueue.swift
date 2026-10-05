import AVFAudio
import Foundation
import Observation

/// FIFO speech playback for chat replies: sentence 1 plays while sentence 2 is
/// still synthesizing. Distinct from PreviewPlayer (single-shot toggle).
///
/// Two kinds of item, played strictly in order:
/// - **Whole clips** (`enqueue(wav:)`): a finished render, one AVAudioPlayer each.
/// - **Streamed segments** (`beginStream` / `appendStream` / `endStream`): a
///   render still in progress. Its pieces are scheduled on one
///   AVAudioPlayerNode as they arrive, back to back with nothing inserted, so a
///   streamed render plays gaplessly from its first piece; consecutive streamed
///   segments chain on the same node with no hand-off gap either. The caller
///   owns the fades (only at a segment's edges, see `StreamEdgeFader`).
///
/// Each item carries the text it voices so the transcript can karaoke-highlight
/// the word being spoken: there is no word-level alignment from the TTS, so the
/// active word is estimated by playback progress, proportional to character
/// position — close enough to follow along.
@MainActor @Observable
final class ChatSpeechQueue: NSObject, AVAudioPlayerDelegate {
    private(set) var isSpeaking = false
    /// Text of the chunk currently sounding, nil when idle.
    private(set) var nowPlayingText: String?

    private final class Segment {
        let id: Int
        let text: String?
        let sampleRate: Int
        /// Pieces received while the segment was still waiting its turn.
        var pending: [[Float]] = []
        var closed = false
        var frames = 0
        init(id: Int, text: String?, sampleRate: Int) {
            self.id = id; self.text = text; self.sampleRate = sampleRate
        }
    }

    private enum Item {
        case clip(wav: Data, text: String?, voiced: ClosedRange<Double>?)
        case stream(Segment)
    }

    @ObservationIgnored private var queue: [Item] = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var voicedWindow: ClosedRange<Double>?

    // Streamed playback.
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var nodeRate: Int = 0
    /// The segment whose pieces go straight to the node as they arrive.
    @ObservationIgnored private var feeding: Segment?
    /// Buffers scheduled on the node and not yet played, oldest first.
    @ObservationIgnored private var outstanding: [(segment: Segment, firstOfSegment: Bool)] = []
    /// The segment audible now, and where in the node's timeline it began.
    @ObservationIgnored private var sounding: Segment?
    @ObservationIgnored private var soundingStart: Double = 0
    /// Bumped by `stop()`: completions from before it are ignored.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var nextSegmentID = 0

    /// `voiced` is the chunk's speech window in seconds (silence trimmed) —
    /// the karaoke estimate maps progress across it instead of the whole file,
    /// otherwise leading/trailing silence makes the highlight lag the voice.
    func enqueue(wav: Data, text: String? = nil, voiced: ClosedRange<Double>? = nil) {
        queue.append(.clip(wav: wav, text: text, voiced: voiced))
        playNextIfIdle()
    }

    /// Opens a streamed segment at the end of the queue; returns its id for
    /// `appendStream` / `endStream`. Plays as soon as it is its turn and has audio.
    func beginStream(text: String?, sampleRate: Int) -> Int {
        nextSegmentID += 1
        queue.append(.stream(Segment(id: nextSegmentID, text: text, sampleRate: sampleRate)))
        isSpeaking = true
        playNextIfIdle()
        return nextSegmentID
    }

    /// The next piece of a streamed segment, in order. Scheduled immediately
    /// when the segment is playing, held until its turn otherwise.
    func appendStream(_ id: Int, samples: [Float]) {
        guard !samples.isEmpty, let segment = segment(id) else { return }
        if feeding === segment {
            schedule(samples, of: segment)
        } else {
            segment.pending.append(samples)
        }
    }

    /// No more audio for the segment: the queue moves on once it has played.
    func endStream(_ id: Int) {
        guard let segment = segment(id) else { return }
        segment.closed = true
        if feeding === segment { feedingClosed() }
    }

    func stop() {
        epoch += 1
        queue.removeAll()
        player?.stop()
        player = nil
        voicedWindow = nil
        feeding = nil
        outstanding.removeAll()
        sounding = nil
        node?.stop()
        audioEngine?.stop()
        isSpeaking = false
        nowPlayingText = nil
    }

    /// Progress through the current chunk's SPEECH (not file), 0…1, with a
    /// small lookahead so the highlight leads rather than trails the ear.
    /// Reading it does not trigger Observation updates — poll from TimelineView.
    var playbackProgress: Double {
        if let segment = sounding {
            guard let now = nodeSampleTime else { return 0 }
            let rate = Double(segment.sampleRate)
            let elapsed = (now - soundingStart) / rate + 0.12
            // While it is still rendering, its length is unknown: assume a
            // speaking pace (about 14 characters a second) until audio says longer.
            let estimate = segment.closed ? 0 : Double(segment.text?.count ?? 0) / 14
            let duration = max(Double(segment.frames) / rate, estimate, 0.05)
            return min(1, max(0, elapsed / duration))
        }
        guard let player, player.duration > 0 else { return 0 }
        let window = voicedWindow ?? 0...player.duration
        let span = max(window.upperBound - window.lowerBound, 0.05)
        let t = player.currentTime + 0.12   // render tick + perception lead
        return min(1, max(0, (t - window.lowerBound) / span))
    }

    private var nodeSampleTime: Double? {
        guard let node, let renderTime = node.lastRenderTime,
              let t = node.playerTime(forNodeTime: renderTime) else { return nil }
        return Double(t.sampleTime)
    }

    private func segment(_ id: Int) -> Segment? {
        if let feeding, feeding.id == id { return feeding }
        for item in queue { if case .stream(let s) = item, s.id == id { return s } }
        return nil
    }

    private func playNextIfIdle() {
        guard player == nil, feeding == nil else { return }
        while let head = queue.first {
            switch head {
            case .clip(let wav, let text, let voiced):
                // A whole clip waits for streamed audio still sounding.
                guard outstanding.isEmpty else { return }
                queue.removeFirst()
                guard let p = try? AVAudioPlayer(data: wav) else { continue }
                p.delegate = self
                p.play()
                player = p
                nowPlayingText = text
                voicedWindow = voiced
                isSpeaking = true
                return
            case .stream(let segment):
                startFeeding(segment)
                return
            }
        }
        if outstanding.isEmpty { becameIdle() }
    }

    private func startFeeding(_ segment: Segment) {
        feeding = segment
        isSpeaking = true
        if sounding == nil { nowPlayingText = segment.text }
        let held = segment.pending
        segment.pending = []
        for samples in held { schedule(samples, of: segment) }
        if segment.closed { feedingClosed() }
    }

    /// The fed segment has all its audio: chain the next streamed segment
    /// straight on (gapless); a whole clip waits for the node to drain.
    private func feedingClosed() {
        guard let done = feeding else { return }
        feeding = nil
        if case .stream(let s)? = queue.first, s === done { queue.removeFirst() }
        if case .stream(let next)? = queue.first {
            startFeeding(next)
        } else if outstanding.isEmpty {
            if done === sounding { sounding = nil }
            playNextIfIdle()
        }
    }

    private func schedule(_ samples: [Float], of segment: Segment) {
        guard let node = prepareNode(sampleRate: segment.sampleRate),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(segment.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let first = segment.frames == 0
        segment.frames += samples.count
        let starved = outstanding.isEmpty
        outstanding.append((segment, first))
        if starved {
            // Nothing ahead of it: it sounds from now.
            if first || sounding == nil {
                sounding = segment
                soundingStart = nodeSampleTime ?? 0
                nowPlayingText = segment.text
            }
        }
        let epoch = self.epoch
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.bufferPlayed(epoch: epoch) }
        }
        if !node.isPlaying { node.play() }
    }

    private func bufferPlayed(epoch: Int) {
        guard epoch == self.epoch, !outstanding.isEmpty else { return }
        outstanding.removeFirst()
        if let next = outstanding.first, next.firstOfSegment {
            sounding = next.segment
            soundingStart = nodeSampleTime ?? soundingStart
            nowPlayingText = next.segment.text
        }
        if outstanding.isEmpty, feeding == nil {
            sounding = nil
            playNextIfIdle()
        }
    }

    /// The node, running at `sampleRate`. A different rate rewires it, which
    /// only happens between replies (every speaking path stops the queue first).
    private func prepareNode(sampleRate: Int) -> AVAudioPlayerNode? {
        let engine = audioEngine ?? AVAudioEngine()
        let node = self.node ?? AVAudioPlayerNode()
        if audioEngine == nil {
            audioEngine = engine
            engine.attach(node)
            self.node = node
        }
        if nodeRate != sampleRate {
            node.stop()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)
            else { return nil }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodeRate = sampleRate
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                AppLog.chat.error("chat speech engine failed to start: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return node
    }

    private func becameIdle() {
        isSpeaking = false
        nowPlayingText = nil
        voicedWindow = nil
        sounding = nil
        // Release the output device between replies.
        if let audioEngine, audioEngine.isRunning {
            node?.stop()
            audioEngine.stop()
        }
    }

    /// First/last clearly-voiced moment in the samples, in seconds.
    static func voicedBounds(samples: [Float], sampleRate: Int) -> ClosedRange<Double>? {
        guard sampleRate > 0,
              let first = samples.firstIndex(where: { abs($0) > 0.02 }),
              let last = samples.lastIndex(where: { abs($0) > 0.02 }),
              first < last
        else { return nil }
        return Double(first) / Double(sampleRate)...Double(last) / Double(sampleRate)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                 successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.playNextIfIdle()
        }
    }
}
