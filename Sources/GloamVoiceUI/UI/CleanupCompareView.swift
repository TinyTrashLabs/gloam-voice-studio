import SwiftUI

/// The noise-cleaned version of a take won the clone-time test render
/// (`VoiceQualifier`); this lets the person hear both previews and keep
/// whichever sounds more like them. Presented from a single row or button,
/// never from a Form `Section` (sheets on Sections never present here).
public struct CleanupCompareView: View {
    /// Both previews: the same line rendered from each version, 48 kHz.
    let original: [Float]
    let cleaned: [Float]
    let onKeepCleaned: () -> Void
    let onUseOriginal: () -> Void

    @StateObject private var player = VoicePlayer()
    @Environment(\.voiceEditorTheme) private var t
    @State private var playing: ReferenceCandidate.Kind?

    public init(original: [Float], cleaned: [Float], onKeepCleaned: @escaping () -> Void, onUseOriginal: @escaping () -> Void) {
        self.original = original; self.cleaned = cleaned
        self.onKeepCleaned = onKeepCleaned; self.onUseOriginal = onUseOriginal
    }

    public var body: some View {
        VStack(spacing: 18) {
            Text("Background noise removed. Listen to both and keep whichever sounds more like you.")
                .font(t.sans(14)).foregroundStyle(t.fg)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)

            HStack(spacing: 12) {
                playButton("Original", kind: .original, samples: original)
                playButton("Cleaned", kind: .cleaned, samples: cleaned)
            }

            Button {
                player.stop(); onKeepCleaned()
            } label: {
                Text("Keep cleaned")
                    .font(t.console(13, .semibold)).foregroundStyle(t.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 13).fill(t.accent))
            }
            .buttonStyle(.plain)

            Button("Use original") { player.stop(); onUseOriginal() }
                .font(t.console(12)).foregroundStyle(t.fgDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.ground)
        .preferredColorScheme(.dark)
        .onChange(of: player.isPlaying) { _, now in if !now { playing = nil } }
        .onDisappear { player.stop() }
        #if DEBUG
        // QA: play both, in turn, with a log line each (headless Simulator).
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--compareautoplay") else { return }
            for (kind, samples) in [(ReferenceCandidate.Kind.original, original), (.cleaned, cleaned)] {
                playing = kind
                try? player.play(samples: samples, sampleRate: 48000)
                NSLog("[compare] playing %@ (%.1f s)", kind.rawValue, Double(samples.count) / 48000)
                try? await Task.sleep(for: .seconds(Double(samples.count) / 48000 + 0.5))
            }
        }
        #endif
    }

    private func playButton(_ title: String, kind: ReferenceCandidate.Kind, samples: [Float]) -> some View {
        let on = playing == kind && player.isPlaying
        return Button {
            player.stop()
            if on { playing = nil; return }
            playing = kind
            try? player.play(samples: samples, sampleRate: 48000)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(t.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(t.accent))
                Text(title).font(t.masthead(15)).foregroundStyle(t.fg)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(t.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? t.accent : t.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Stop \(title.lowercased())" : "Play \(title.lowercased())")
    }
}
