// Run: swiftc -parse-as-library App/PreviewPlayer.swift
//      Tests/AppPlaybackTests/PreviewPlayerChecks.swift -o /tmp/preview-player-checks
// This standalone harness exercises the app's AVAudioPlayer without loading MLX.
import Foundation

@main struct PreviewPlayerChecks {
    @MainActor static func main() {
        var wav = Data()
        func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        let count: UInt32 = 24_000 * 10
        ascii("RIFF"); u32(36 + count * 2); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        ascii("data"); u32(count * 2); wav.append(Data(count: Int(count * 2)))
        let player = PreviewPlayer()
        player.seek(id: "take", data: wav, fraction: 0.6)
        precondition(abs(player.position(for: "take") - 6) < 0.05)
        precondition(player.playingID == nil, "Seeking a stopped take must not autoplay")
        player.togglePlayback(id: "take", data: wav)
        precondition(player.playingID == "take")
        precondition(player.position(for: "take") >= 5.95, "Play must retain the seek position")
        player.seek(id: "take", data: wav, fraction: 0.7)
        precondition(player.playingID == "take", "Seeking while playing must keep playing")
        precondition(player.position(for: "take") >= 6.95)
        player.togglePlayback(id: "take", data: wav)
        precondition(player.playingID == nil)
        precondition(player.position(for: "take") >= 5.95, "Pause must retain position")
        player.seek(id: "take", data: wav, fraction: -1)
        precondition(player.position(for: "take") == 0)
        player.seek(id: "take", data: wav, fraction: 2)
        precondition(abs(player.position(for: "take") - 10) < 0.05)
        player.seek(id: "other", data: wav, fraction: 0.2)
        precondition(player.position(for: "take") == 0)
        precondition(abs(player.position(for: "other") - 2) < 0.05)
        player.seek(id: "other", data: wav, fraction: .nan)
        precondition(abs(player.position(for: "other") - 2) < 0.05)
        var replacement = wav
        replacement[44] = 1
        player.togglePlayback(id: "other", data: replacement)
        precondition(player.position(for: "other") < 1, "New take with same ID must replace old audio")
        player.stop()
        precondition(player.position(for: "other") == 0)
        print("PreviewPlayer checks passed")
    }
}
