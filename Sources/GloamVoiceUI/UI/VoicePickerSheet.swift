import SwiftUI

/// Full-screen voice picker for Compose, opened from the voice rail. Scales
/// to a large roster the way the old horizontal card rail couldn't: a search
/// field (shared with the Voices tab) over a scrollable list of every voice.
public struct VoicePickerSheet: View {
    let voices: [Voice]
    let selected: Voice?
    let onPick: (Voice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceEditorTheme) private var t
    @State private var query = ""

    public init(voices: [Voice], selected: Voice?, onPick: @escaping (Voice) -> Void) {
        self.voices = voices; self.selected = selected; self.onPick = onPick
    }

    public var body: some View {
        ZStack {
            t.ground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Voice").font(t.masthead(24)).foregroundStyle(t.fg)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.fgDim)
                            .frame(width: 34, height: 34).background(Circle().fill(t.panel))
                    }.buttonStyle(.plain)
                }
                VoiceSearchField(query: $query)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(VoiceFilter.apply(voices, query: query)) { v in
                            Button {
                                onPick(v)
                            } label: {
                                row(for: v)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private func row(for v: Voice) -> some View {
        let isSelected = v.id == selected?.id
        return HStack(spacing: 13) {
            VoiceAvatarView(voice: v, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(t.masthead(17)).foregroundStyle(t.fg)
                Text(v.blurb).font(t.console(10)).foregroundStyle(t.fgFaint).lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(t.accent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            t.accent.opacity(0.25), lineWidth: 1))
    }
}
