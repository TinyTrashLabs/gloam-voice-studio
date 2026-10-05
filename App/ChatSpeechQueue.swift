import AVFAudio
import EngineKit
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
/// A streamed reply is **paced** (`beginPacing` … `finishPacing`): the node holds until the queued
/// audio covers the shortfall `PlaybackPacer` projects over the rest of the reply, so a render near real
/// time plays through instead of underrunning between chunks; if it still runs dry mid-reply, the node
/// pauses and re-buffers once (a longer lead each time) rather than stuttering chunk by chunk.
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
    @ObservationIgnored private var outstanding: [(segment: Segment, firstOfSegment: Bool, frames: Int)] = []
    /// The segment audible now, and where in the node's timeline it began.
    @ObservationIgnored private var sounding: Segment?
    @ObservationIgnored private var soundingStart: Double = 0
    /// Bumped by `stop()`: completions from before it are ignored.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var nextSegmentID = 0

    // Pacing (a streamed reply, `beginPacing` … `finishPacing`).
    @ObservationIgnored private var pacer: PlaybackPacer?
    @ObservationIgnored private var pacingStart = ContinuousClock.now
    /// The node is holding for lead: buffers are scheduled but it is not playing.
    @ObservationIgnored private var held = false
    /// The node's sample time when it was paused (a paused node reports none).
    @ObservationIgnored private var heldAt: Double = 0
    /// Audio queued when the reply first started sounding.
    @ObservationIgnored private var initialLead: Double?

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
        pacer?.chunkArrived(seconds: Double(samples.count) / Double(segment.sampleRate), at: pacingElapsed)
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

    /// A streamed reply starts: hold playback until the pacer says it can play through.
    /// `expectedSeconds` is the reply's whole expected audio (update it with `pacingExpects`).
    func beginPacing(expectedSeconds: Double) {
        pacer = PlaybackPacer(tuning: .mac, expectedSeconds: expectedSeconds)
        pacingStart = .now
        initialLead = nil
        if outstanding.isEmpty {
            heldAt = nodeSampleTime ?? 0
            held = true
            if node?.isPlaying == true { node?.pause() }
        }
    }

    /// The reply's expected audio changed (more text arrived, or its speech rate was measured).
    func pacingExpects(seconds: Double) {
        guard pacer != nil else { return }
        pacer?.expectedSeconds = seconds
        releaseIfReady()
    }

    /// The reply has rendered all its audio: play out whatever is held, then go idle.
    func finishPacing() {
        guard pacer != nil else { return }
        logPacing()
        pacer = nil
        releaseIfReady()
        if held, outstanding.isEmpty { held = false }
        if outstanding.isEmpty, feeding == nil { playNextIfIdle() }
    }

    func stop() {
        if pacer != nil { logPacing() }
        pacer = nil
        held = false
        initialLead = nil
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
              let t = node.playerTime(forNodeTime: renderTime) else { return held ? heldAt : nil }
        return Double(t.sampleTime)
    }

    private var pacingElapsed: Double {
        let d = pacingStart.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    /// Audio scheduled on the node and not yet played (exact while held).
    private var queuedSeconds: Double {
        guard nodeRate > 0 else { return 0 }
        return Double(outstanding.reduce(0) { $0 + $1.frames }) / Double(nodeRate)
    }

    /// Starts (or resumes) a held node once the pacer says the queue will play through.
    private func releaseIfReady() {
        guard held, let node, !outstanding.isEmpty else { return }
        let queued = queuedSeconds
        if let pacer, !pacer.mayPlay(queued: queued, renderFinished: false) { return }
        held = false
        if initialLead == nil { initialLead = queued }
        node.play()
    }

    /// The node ran dry mid-reply: pause it and hold again, with a longer lead.
    private func drained() {
        pacer?.drained()
        heldAt = nodeSampleTime ?? heldAt
        node?.pause()
        held = true
    }

    private func logPacing() {
        guard let pacer else { return }
        let rate = pacer.renderRate.map { String(format: "%.2fx", $0) } ?? "n/a"
        let lead = initialLead.map { String(format: "%.1fs", $0) } ?? "n/a"
        AppLog.chat.log("[chat-speech] pacer: rate \(rate, privacy: .public), lead \(lead, privacy: .public), drains \(pacer.drains, privacy: .public)")
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
        // A paced reply between segments (the next one still in prefill) is not idle.
        if outstanding.isEmpty, pacer == nil { becameIdle() }
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
        outstanding.append((segment, first, samples.count))
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
        if held {
            releaseIfReady()
        } else if !node.isPlaying {
            node.play()
        }
    }

    private func bufferPlayed(epoch: Int) {
        guard epoch == self.epoch, !outstanding.isEmpty else { return }
        outstanding.removeFirst()
        if let next = outstanding.first, next.firstOfSegment {
            sounding = next.segment
            soundingStart = nodeSampleTime ?? soundingStart
            nowPlayingText = next.segment.text
        }
        guard outstanding.isEmpty else { return }
        if pacer != nil {
            // Ran dry before the reply finished rendering: re-buffer instead of
            // playing each late chunk the moment it lands.
            if feeding == nil { sounding = nil }
            drained()
            return
        }
        if feeding == nil {
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
