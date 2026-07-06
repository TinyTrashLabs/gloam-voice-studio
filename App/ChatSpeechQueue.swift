import AVFAudio
import Foundation
import Observation

/// FIFO speech playback for chat replies: sentence 1 plays while sentence 2 is
/// still synthesizing. Distinct from PreviewPlayer (single-shot toggle).
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
    private var queue: [(wav: Data, text: String?, voiced: ClosedRange<Double>?)] = []
    private var player: AVAudioPlayer?
    private var voicedWindow: ClosedRange<Double>?

    /// `voiced` is the chunk's speech window in seconds (silence trimmed) —
    /// the karaoke estimate maps progress across it instead of the whole file,
    /// otherwise leading/trailing silence makes the highlight lag the voice.
    func enqueue(wav: Data, text: String? = nil, voiced: ClosedRange<Double>? = nil) {
        queue.append((wav, text, voiced))
        playNextIfIdle()
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        isSpeaking = false
        nowPlayingText = nil
        voicedWindow = nil
    }

    /// Progress through the current chunk's SPEECH (not file), 0…1, with a
    /// small lookahead so the highlight leads rather than trails the ear.
    /// Reading it does not trigger Observation updates — poll from TimelineView.
    var playbackProgress: Double {
        guard let player, player.duration > 0 else { return 0 }
        let window = voicedWindow ?? 0...player.duration
        let span = max(window.upperBound - window.lowerBound, 0.05)
        let t = player.currentTime + 0.12   // render tick + perception lead
        return min(1, max(0, (t - window.lowerBound) / span))
    }

    private func playNextIfIdle() {
        guard player == nil else { return }
        while !queue.isEmpty {
            let item = queue.removeFirst()
            guard let p = try? AVAudioPlayer(data: item.wav) else { continue }
            p.delegate = self
            p.play()
            player = p
            nowPlayingText = item.text
            voicedWindow = item.voiced
            isSpeaking = true
            return
        }
        isSpeaking = false
        nowPlayingText = nil
        voicedWindow = nil
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
