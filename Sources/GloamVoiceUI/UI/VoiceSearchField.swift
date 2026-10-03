import SwiftUI

/// Search box shared by the Voices tab and the Compose voice picker sheet —
/// same panel styling as the surrounding cards, a leading magnifying glass,
/// and a clear button once there's something to clear.
public struct VoiceSearchField: View {
    @Binding var query: String
    @Environment(\.voiceEditorTheme) private var t

    public init(query: Binding<String>) { _query = query }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(t.fgDim)
            TextField("Search voices", text: $query)
                .font(t.sans(15))
                .foregroundStyle(t.fg)
                .autocorrectionDisabled()
                .voiceNoAutocapitalization()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(t.fgDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(t.panelStroke, lineWidth: 1))
    }
}
