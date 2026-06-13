import StudioKit
import SwiftUI

struct VoiceCatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var manager = VoiceCatalogManager()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browse Voices")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Brand.fg)
                        Text("Free CC0 voices — downloaded and saved to your library on demand.")
                            .font(.callout)
                            .foregroundStyle(Brand.fgDim)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                TextField("Search by name or language…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .accessibilityIdentifier("catalog-search")
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            .background(Brand.ink2)

            Divider().opacity(0.2)

            // Voice list
            let installedSlugs = Set(model.voices.list().map(\.slug))
            List(filteredVoices) { voice in
                catalogRow(voice, installedSlugs: installedSlugs)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Brand.ink)
    }

    // MARK: - Row

    @ViewBuilder
    private func catalogRow(_ voice: CatalogVoice, installedSlugs: Set<String>) -> some View {
        HStack(spacing: 10) {
            VoiceAvatarView(slug: voice.id, name: voice.name, avatarURL: nil, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(voice.name)
                    .foregroundStyle(Brand.fg)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    chip(voice.language, tint: Brand.fgDim)
                    chip(voice.license, tint: Brand.accent)
                }
            }

            Spacer(minLength: 8)

            trailingControl(voice, installedSlugs: installedSlugs)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func trailingControl(_ voice: CatalogVoice, installedSlugs: Set<String>) -> some View {
        let currentState = manager.state(for: voice, installedSlugs: installedSlugs)
        switch currentState {
        case .available:
            Button("Install") {
                manager.install(voice, into: model.voices)
            }
            .accessibilityIdentifier("install-voice")
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress > 0 ? progress : nil)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(progress > 0 ? "\(Int(progress * 100))%" : "Downloading…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Brand.fgDim)
            }

        case .installed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Brand.accent)
                Text("Installed")
                    .foregroundStyle(Brand.fgDim)
                    .font(.system(size: 12))
            }
            .onAppear {
                // Refresh the voice sidebar after installation.
                model.voicesVersion += 1
            }

        case .failed(let msg):
            Button("Retry") {
                manager.install(voice, into: model.voices)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(msg)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
            .foregroundStyle(tint == Brand.accent ? Brand.accent : Brand.fgDim)
            .lineLimit(1)
    }

    private var filteredVoices: [CatalogVoice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = manager.voices.sorted { a, b in
            let aEn = a.language.lowercased().hasPrefix("en")
            let bEn = b.language.lowercased().hasPrefix("en")
            if aEn != bEn { return aEn }
            return a.name.lowercased() < b.name.lowercased()
        }
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q) || $0.language.lowercased().contains(q)
        }
    }
}
