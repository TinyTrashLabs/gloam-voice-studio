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

            let sampleCount = pcm.count / 2
            guard sampleCount > 0 else { return }

            let bins = max(1, Int(size.width / 2))
            let samplesPerBin = max(1, sampleCount / bins)
            let mid = size.height / 2

            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)

                // --- 2. First pass: find global peak for self-normalization ---
                var globalPeak: Float = 0
                for i in 0..<sampleCount {
                    globalPeak = max(globalPeak, abs(Float(Int16(littleEndian: samples[i]))))
                }
                // Guard against silence / near-silence — draw a flat centerline
                let epsilon: Float = 1e-4 * 32767  // ~3 counts
                guard globalPeak > epsilon else {
                    // Flat 1px centerline
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
                    for i in start..<end {
                        binPeak = max(binPeak, abs(Float(Int16(littleEndian: samples[i]))))
                    }
                    // Normalize to clip peak so quiet takes fill the view height
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
