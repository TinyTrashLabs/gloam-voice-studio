import SwiftUI

// MARK: - Record orb

/// The big record button: a gradient orb that breathes while recording and
/// squares off into a stop button.
public struct RecordOrb: View {
    let recording: Bool
    let action: () -> Void
    @State private var pulse = false
    @Environment(\.voiceEditorTheme) private var t

    public init(recording: Bool, action: @escaping () -> Void) {
        self.recording = recording; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                // breathing rings while recording
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(t.accent.opacity(recording ? 0.28 - Double(i) * 0.08 : 0), lineWidth: 2)
                        .frame(width: 96 + CGFloat(i) * 26, height: 96 + CGFloat(i) * 26)
                        .scaleEffect(pulse ? 1.08 : 0.96)
                        .animation(recording ? .easeInOut(duration: 1.1).repeatForever().delay(Double(i) * 0.18) : .default, value: pulse)
                }
                Circle()
                    .fill(t.gradient)
                    .frame(width: 96, height: 96)
                    .shadow(color: t.violet.opacity(0.55), radius: 26)
                RoundedRectangle(cornerRadius: recording ? 7 : 48, style: .continuous)
                    .fill(t.ink)
                    .frame(width: recording ? 30 : 40, height: recording ? 30 : 40)
                    .animation(.spring(duration: 0.35), value: recording)
            }
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
    }
}

// MARK: - Live waveform (mic-reactive)

public struct LiveWaveform: View {
    let levels: [Float]
    let active: Bool
    @Environment(\.voiceEditorTheme) private var t

    public init(levels: [Float], active: Bool) { self.levels = levels; self.active = active }

    public var body: some View {
        GeometryReader { geo in
            let bins = 48
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bins, id: \.self) { i in
                    let v = value(at: i, bins: bins)
                    Capsule()
                        .fill(active ? t.accent.opacity(0.55 + 0.45 * Double(v)) : t.fgFaint.opacity(0.5))
                        .frame(width: (geo.size.width - CGFloat(bins - 1) * 3) / CGFloat(bins),
                               height: max(3, CGFloat(v) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    /// Map the newest `levels` onto the rightmost bins so it scrolls left.
    private func value(at i: Int, bins: Int) -> Float {
        guard !levels.isEmpty else { return active ? 0.05 : 0.04 }
        let idx = levels.count - bins + i
        return idx >= 0 && idx < levels.count ? min(1, levels[idx]) : 0.04
    }
}
