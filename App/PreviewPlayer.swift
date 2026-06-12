import AVFAudio
import Foundation

@MainActor
@Observable
final class PreviewPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private(set) var playingID: String?
    private var player: AVAudioPlayer?
    // Monotonic generation counter so nonisolated delegate can post without
    // capturing the AVAudioPlayer across actor boundaries.
    private var generation: Int = 0

    func toggle(id: String, data: Data) {
        if playingID == id { stop(); return }
        player?.stop()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        generation &+= 1
        p.delegate = self
        p.play()
        player = p
        playingID = id
    }

    func toggle(id: String, url: URL) {
        if playingID == id { stop(); return }
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        generation &+= 1
        p.delegate = self
        p.play()
        player = p
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.didFinish()
        }
    }

    private func didFinish() {
        player = nil
        playingID = nil
    }
}
