import SwiftUI

/// Peak-bin waveform from 16-bit PCM wav data (skips the 44-byte header).
struct WaveformView: View {
    let wavData: Data
    var color: Color = Brand.accent

    var body: some View {
        Canvas { context, size in
            let pcm = wavData.dropFirst(44)
            let sampleCount = pcm.count / 2
            guard sampleCount > 0 else { return }
            let bins = max(1, Int(size.width / 2))
            let samplesPerBin = max(1, sampleCount / bins)
            let mid = size.height / 2
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for bin in 0..<bins {
                    let start = bin * samplesPerBin
                    let end = min(start + samplesPerBin, sampleCount)
                    guard start < end else { break }
                    var peak: Float = 0
                    for i in start..<end {
                        peak = max(peak, abs(Float(Int16(littleEndian: samples[i]))) / 32767)
                    }
                    let h = max(1, CGFloat(peak) * mid)
                    let x = CGFloat(bin) * 2
                    context.fill(
                        Path(CGRect(x: x, y: mid - h, width: 1.4, height: h * 2)),
                        with: .color(color.opacity(0.85)))
                }
            }
        }
    }
}
