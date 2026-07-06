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
    private var queue: [(wav: Data, text: String?)] = []
    private var player: AVAudioPlayer?

    func enqueue(wav: Data, text: String? = nil) {
        queue.append((wav, text))
        playNextIfIdle()
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        isSpeaking = false
        nowPlayingText = nil
    }

    /// Playback progress through the current chunk, 0…1. Reading it does not
    /// trigger Observation updates — poll it from a TimelineView.
    var playbackProgress: Double {
        guard let player, player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
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
            isSpeaking = true
            return
        }
        isSpeaking = false
        nowPlayingText = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                 successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.playNextIfIdle()
        }
    }
}
