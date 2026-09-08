import SwiftUI

/// Peak-bin waveform rendered from 16-bit PCM WAV data.
///
/// Parsing: scans RIFF chunks to locate the `data` subchunk so we never
/// ingest trailing LIST/INFO bytes (present on exported files with provenance).
/// Falls back to the legacy dropFirst(44) approach if RIFF parsing fails.
///
/// Self-normalization: a first pass finds the clip's own global peak, then
/// scales each bin bar relative to that peak so quiet Fish clips (which can
/// peak at <10% full-scale) still render a full-height waveform shape.
struct WaveformView: View {
    let wavData: Data
    var color: Color = Brand.accent

    var body: some View {
        Canvas { context, size in
            // --- 1. Locate the PCM data chunk via RIFF chunk scanning ---
            let pcm: Data
            if let found = extractPCMData(from: wavData) {
                pcm = found
            } else {
                // Fallback: legacy fixed-offset approach
                pcm = Data(wavData.dropFirst(44))
            }

            // 16-bit PCM (fmt tag 1) or 32-bit IEEE float (fmt tag 3): the app's
            // own encoder emits PCM16, but engine/harness/dropped clips can be
            // float — decode both to a normalized -1…1 Float so either draws.
            let isFloat = Self.isFloatFormat(wavData)
            let bytesPerSample = isFloat ? 4 : 2
            let sampleCount = pcm.count / bytesPerSample
            guard sampleCount > 0 else { return }

            let bins = max(1, Int(size.width / 2))
            let samplesPerBin = max(1, sampleCount / bins)
            let mid = size.height / 2

            pcm.withUnsafeBytes { raw in
                func sample(_ i: Int) -> Float {
                    if isFloat {
                        return raw.loadUnaligned(fromByteOffset: i * 4, as: Float32.self)
                    }
                    let s = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                    return Float(Int16(littleEndian: s)) / 32767.0
                }

                // --- 2. First pass: find global peak for self-normalization ---
                var globalPeak: Float = 0
                for i in 0..<sampleCount { globalPeak = max(globalPeak, abs(sample(i))) }
                // Guard against silence / near-silence — draw a flat centerline
                guard globalPeak > 1e-4 else {
                    context.fill(
                        Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                        with: .color(color.opacity(0.4)))
                    return
                }

                // --- 3. Second pass: render bins, scaled to clip's own peak ---
                for bin in 0..<bins {
                    let start = bin * samplesPerBin
                    let end = min(start + samplesPerBin, sampleCount)
                    guard start < end else { break }
                    var binPeak: Float = 0
                    for i in start..<end { binPeak = max(binPeak, abs(sample(i))) }
                    let h = max(1, CGFloat(binPeak / globalPeak) * mid)
                    let x = CGFloat(bin) * 2
                    context.fill(
                        Path(CGRect(x: x, y: mid - h, width: 1.4, height: h * 2)),
                        with: .color(color.opacity(0.85)))
                }
            }
        }
    }

    /// Scan RIFF chunks, return only the bytes within the `data` subchunk.
    /// Returns nil if the file doesn't parse as a valid RIFF/WAVE.
    /// True if the WAV's `fmt ` chunk declares IEEE float samples (format tag 3);
    /// false for PCM (tag 1) or when the tag can't be read.
    static func isFloatFormat(_ data: Data) -> Bool {
        guard data.count > 12,
              data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return false }
        var pos = 12
        while pos + 8 <= data.count {
            let chunkID = data[pos..<(pos + 4)]
            let size = Int(UInt32(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self) }))
            let start = pos + 8
            guard start + size <= data.count else { break }
            if chunkID == Data("fmt ".utf8), size >= 2 {
                let tag = UInt16(littleEndian: data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: start, as: UInt16.self) })
                return tag == 3
            }
            pos = start + size + (size % 2 == 1 ? 1 : 0)
        }
        return false
    }

    private func extractPCMData(from data: Data) -> Data? {
        guard data.count > 12 else { return nil }
        // Verify RIFF/WAVE header
        guard data[0..<4] == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }

        var pos = 12
        while pos + 8 <= data.count {
            let chunkID = data[pos..<(pos + 4)]
            let chunkSize = data.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self)
            }
            let chunkSizeLE = UInt32(littleEndian: chunkSize)
            let dataStart = pos + 8
            let dataEnd = dataStart + Int(chunkSizeLE)
            guard dataEnd <= data.count else { break }

            if chunkID == Data("data".utf8) {
                // Found the audio data chunk — slice exactly these bytes
                return data[dataStart..<dataEnd]
            }
            // Advance, word-aligned
            pos = dataEnd + (chunkSizeLE % 2 == 1 ? 1 : 0)
        }
        return nil
    }
}

/// A take can be cued while paused, or scrubbed while it is playing.
struct SeekableWaveformView: View {
    let wavData: Data
    let id: String
    let player: PreviewPlayer

    var body: some View {
        WaveformView(wavData: wavData)
            .overlay {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 0.05,
                                            paused: player.playingID != id)) { _ in
                        let duration = player.duration(for: id)
                        let position = player.position(for: id)
                        let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
                        Rectangle()
                            .fill(Brand.fg)
                            .frame(width: 2)
                            .offset(x: max(0, (geometry.size.width - 2) * fraction))
                    }
                    .allowsHitTesting(false)
                    // The seek layer carries the accessibility annotations too.
                    // Reading `player.position` here scopes the observation to
                    // this overlay subtree, so a seek re-evaluates only the
                    // playhead — not the sibling WaveformView, which would
                    // otherwise re-decode the whole WAV on every drag tick.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard geometry.size.width > 0 else { return }
                                player.seek(id: id, data: wavData,
                                            fraction: value.location.x / geometry.size.width)
                            })
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(Int(player.position(for: id))) seconds")
                        .accessibilityAdjustableAction { direction in
                            let duration = player.duration(for: id)
                            let delta: Double = direction == .increment ? 5 : -5
                            // Load on the first keyboard adjustment, then use its duration.
                            if duration == 0 { player.seek(id: id, data: wavData, fraction: 0) }
                            let loadedDuration = player.duration(for: id)
                            guard loadedDuration > 0 else { return }
                            player.seek(id: id, data: wavData,
                                        fraction: (player.position(for: id) + delta) / loadedDuration)
                        }
                        .help("Click or drag to seek")
                }
            }
    }
}
