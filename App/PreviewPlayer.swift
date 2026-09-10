import AVFAudio
import Foundation

@MainActor
@Observable
final class PreviewPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private(set) var playingID: String?
    private var player: AVAudioPlayer?
    private(set) var loadedID: String?
    private var loadedData: Data?
    private var positionRevision = 0

    func toggle(id: String, data: Data) {
        if playingID == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        loadedID = id
        p.delegate = self
        guard p.play() else { stop(); return }
        player = p
        playingID = id
    }

    func toggle(id: String, url: URL) {
        if playingID == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        loadedID = id
        p.delegate = self
        guard p.play() else { stop(); return }
        player = p
        playingID = id
    }

    /// Pauses and resumes a take, preserving a position chosen before playback.
    func togglePlayback(id: String, data: Data) {
        guard load(id: id, data: data), let player else { return }
        if playingID == id {
            player.pause()
            playingID = nil
        } else {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            if player.play() { playingID = id }
        }
    }

    func seek(id: String, data: Data, fraction: Double) {
        guard fraction.isFinite, load(id: id, data: data), let player else { return }
        player.currentTime = min(1, max(0, fraction)) * player.duration
        positionRevision &+= 1
    }

    func position(for id: String) -> Double {
        _ = positionRevision
        return loadedID == id ? (player?.currentTime ?? 0) : 0
    }

    func duration(for id: String) -> Double {
        loadedID == id ? (player?.duration ?? 0) : 0
    }

    private func load(id: String, data: Data) -> Bool {
        // Dialogue reuses its ID for every generation. Compare data as well so
        // a replacement take never resumes the previous take's audio.
        if loadedID == id, loadedData == data, player != nil { return true }
        stop()
        guard let next = try? AVAudioPlayer(data: data) else { return false }
        next.delegate = self
        next.prepareToPlay()
        player = next
        loadedID = id
        loadedData = data
        return true
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        loadedID = nil
        loadedData = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player,
                  ObjectIdentifier(current) == identity, !current.isPlaying else { return }
            self.playingID = nil
            current.currentTime = 0
            self.positionRevision &+= 1
        }
    }
}
