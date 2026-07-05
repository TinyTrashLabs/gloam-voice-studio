import AVFAudio
import Foundation
import Observation

/// FIFO speech playback for chat replies: sentence 1 plays while sentence 2 is
/// still synthesizing. Distinct from PreviewPlayer (single-shot toggle).
@MainActor @Observable
final class ChatSpeechQueue: NSObject, AVAudioPlayerDelegate {
    private(set) var isSpeaking = false
    private var queue: [Data] = []
    private var player: AVAudioPlayer?

    func enqueue(wav: Data) {
        queue.append(wav)
        playNextIfIdle()
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        isSpeaking = false
    }

    private func playNextIfIdle() {
        guard player == nil else { return }
        while !queue.isEmpty {
            let data = queue.removeFirst()
            guard let p = try? AVAudioPlayer(data: data) else { continue }
            p.delegate = self
            p.play()
            player = p
            isSpeaking = true
            return
        }
        isSpeaking = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                 successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.playNextIfIdle()
        }
    }
}
