import SwiftUI

/// Everything about a voice a new user does not need on the first screen:
/// the takes list, the reference window, delivery, emotion versions,
/// renditions, provenance. Pushed
/// from the voice screen's Advanced row; shares the voice screen's
/// `TakesModel` so both Saves see the same takes.
public struct VoiceAdvancedView: View {
    let slug: String
    @ObservedObject var takes: TakesModel
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t
    @StateObject private var player = VoicePlayer()
    @Environment(\.dismiss) private var dismiss
    /// The voice's own delivery pace (pack field); 1.00× = as recorded.
    @State private var voicePace = 1.0
    /// Per-voice loudness trim in dB (pack field); 0 = the reference standard.
    @State private var voiceGain = 0.0
    @State private var confirmingDiscard = false
    @State private var errorText: String?

    public init(slug: String, takes: TakesModel) { self.slug = slug; self.takes = takes }

    private var store: any VoiceLibraryStore { host.store }
    private var voice: Voice? { store.voices.first { $0.slug == slug } }
    private var hasPace: Bool { store.features.contains(.pace) }
    private var hasGain: Bool { store.features.contains(.gain) }
    private var isDirty: Bool {
        guard let voice else { return false }
        return (hasPace && abs(voicePace - store.pace(for: voice)) > 0.005)
            || (hasGain && abs(voiceGain - (voice.meta.gain ?? 0)) > 0.05)
            || takes.state.stale
    }
    private var canSave: Bool { isDirty && !(takes.state.stale && takes.state.blocker != nil) }

    public var body: some View {
        Form {
            if let voice {
                if store.features.contains(.takes) {
                    TakesSection(voice: voice, model: takes, player: player)
                }
                if store.features.contains(.referenceWindow) { windowSection(voice) }
            }
            if hasPace || hasGain { deliverySection }
            if let voice {
                if store.features.contains(.emotionVersions) {
                    EmotionVersionsSection(voice: voice, player: player)
                }
                if store.features.contains(.renditions) { RenditionsSection(voice: voice) }
                if store.features.contains(.provenance) { provenanceSection(voice) }
            }
        }
        .scrollContentBackground(.hidden)
        .voiceFormStyle()
        .background(t.ground)
        .voiceInlineTitle()
        .unsavedChangesGuard(isDirty: isDirty, canSave: canSave, confirming: $confirmingDiscard,
                             message: takes.state.stale
                                 ? "The takes are kept either way; the master is only rebuilt when you save."
                                 : "Your delivery changes haven't been saved.",
                             save: save)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("Advanced").font(t.masthead(18)).foregroundStyle(t.fg) }
            ToolbarItem(placement: .voiceTrailing) {
                Button("Save") { save() }.disabled(!canSave).font(t.console(13, .semibold)).tint(t.accent)
            }
        }
        .onAppear {
            if let voice { voicePace = store.pace(for: voice); voiceGain = voice.meta.gain ?? 0 }
        }
        .onDisappear { player.stop() }
        .preferredColorScheme(.dark)
        .alert("Couldn't do that", isPresented: .init(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: sections

    /// Offered once the master runs long enough that where the engine
    /// listens matters; the row says where it listens now.
    @ViewBuilder
    private func windowSection(_ voice: Voice) -> some View {
        if let seconds = store.masterSeconds(of: voice.slug), seconds > ReferenceWindowRule.adviseAboveSeconds || voice.hasWindow {
            Section {
                NavigationLink {
                    ReferenceWindowEditor(voice: voice)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if let w = store.window(of: voice.slug) {
                            Text(w.derivedFrom.map { ReferenceWindowRule.rangeLabel(start: $0.startSeconds, end: $0.endSeconds) } ?? "Curated window")
                                .font(t.console(12, .semibold)).foregroundStyle(t.accent)
                            Text(w.text).font(t.sans(12)).foregroundStyle(t.fgFaint).lineLimit(2)
                        } else {
                            Text(String(format: "Whole master · %@", TakesSection.timeString(seconds)))
                                .font(t.console(12, .semibold)).foregroundStyle(t.accent)
                            Text("Each engine picks its own section. Choose the part yourself.")
                                .font(t.sans(12)).foregroundStyle(t.fgFaint)
                        }
                    }
                }
                .accessibilityIdentifier("reference-window")
            } header: {
                Text("Reference window").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
            } footer: {
                Text("A window you set travels in the pack, so every device listens to the same part.")
                    .font(t.sans(11)).foregroundStyle(t.fgFaint)
            }
            .listRowBackground(t.panel)
        }
    }

    private var deliverySection: some View {
        Section {
            if hasPace {
                LabeledContent {
                    Text(abs(voicePace - 1) < 0.005 ? "as recorded" : String(format: "%.2f×", voicePace))
                        .font(t.console(12, .semibold)).foregroundStyle(t.accent)
                } label: { Text("Pace").font(t.sans(14)).foregroundStyle(t.fg) }
                Slider(value: $voicePace, in: store.paceRange, step: 0.05).tint(t.accent)
                    .accessibilityLabel("Voice pace")
            }
            if hasGain {
                LabeledContent {
                    Text(abs(voiceGain) < 0.05 ? "standard" : String(format: "%+.1f dB", voiceGain))
                        .font(t.console(12, .semibold)).foregroundStyle(t.accent)
                } label: { Text("Loudness trim").font(t.sans(14)).foregroundStyle(t.fg) }
                Slider(value: $voiceGain, in: -12...12, step: 0.5).tint(t.accent)
                    .accessibilityLabel("Loudness trim")
            }
            if hasPace, let lux = voice?.meta.enginePace?["lux-tts"], lux > 0 {
                Text(String(format: "The pack sets %.2f× for lux-tts; Save writes your pace as the voice's own and drops that override.", lux))
                    .font(t.sans(11)).foregroundStyle(t.fgFaint)
            }
            ForEach(RenditionsSection.paceOverrides(voice?.meta.enginePace), id: \.engine) { o in
                LabeledContent {
                    Text(String(format: "%.2f×", o.pace)).font(t.console(12)).foregroundStyle(t.fgFaint)
                } label: {
                    Text("\(o.engine) pace").font(t.sans(13)).foregroundStyle(t.fgDim)
                }
            }
        } header: {
            Text("Delivery").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
        } footer: {
            Text("How this voice is delivered, travelling with the pack. Pace: a slow, deliberate recording reads better a little faster. Loudness: every reference is levelled to the same standard, but two voices at that level still sit differently in a mix; trim this one up or down.")
                .font(t.sans(11)).foregroundStyle(t.fgFaint)
        }
        .listRowBackground(t.panel)
    }

    @ViewBuilder
    private func provenanceSection(_ voice: Voice) -> some View {
        if let prov = voice.meta.provenance {
            Section {
                ForEach(Array(ProvenanceLines.flatten(prov).enumerated()), id: \.offset) { _, line in
                    LabeledContent {
                        Text(line.value).font(t.console(11)).foregroundStyle(t.fgFaint)
                            .multilineTextAlignment(.trailing).lineLimit(3)
                    } label: {
                        Text(line.key.isEmpty ? "value" : line.key).font(t.console(11)).foregroundStyle(t.fg)
                    }
                }
            } header: {
                Text("Provenance").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
            } footer: {
                Text("How the pack was made, as its producing tool recorded it. Kept exactly as received when the pack is shared on.")
                    .font(t.sans(11)).foregroundStyle(t.fgFaint)
            }
            .listRowBackground(t.panel)
        }
    }

    private func save() {
        do {
            let rebuilding = takes.state.stale && takes.state.blocker == nil
            if hasPace, let voice, abs(voicePace - store.pace(for: voice)) > 0.005 {
                try store.setPace(of: voice, voicePace)
            }
            if hasGain, let voice, abs(voiceGain - (voice.meta.gain ?? 0)) > 0.05 {
                try store.setGain(of: voice, voiceGain)
            }
            if rebuilding { try takes.rebuildMaster() }
        } catch { errorText = userMessage(for: error) }
    }
}

/// A dirty screen asks before its edits are lost: the system back button
/// gives way to one that checks first. Shared by the voice screen and its
/// Advanced screen.
struct UnsavedChangesGuard: ViewModifier {
    @Environment(\.voiceEditorTheme) private var t
    let isDirty: Bool
    let canSave: Bool
    @Binding var confirming: Bool
    let message: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .voiceLeading) {
                        Button { confirming = true } label: { Label("Back", systemImage: "chevron.backward") }
                            .tint(t.accent)
                            .accessibilityIdentifier("editor-back")
                    }
                }
            }
            .confirmationDialog("Unsaved changes", isPresented: $confirming, titleVisibility: .visible) {
                if canSave {
                    Button("Save and go back") { save(); dismiss() }
                }
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: { Text(message) }
    }
}

extension View {
    func unsavedChangesGuard(isDirty: Bool, canSave: Bool, confirming: Binding<Bool>, message: String,
                             save: @escaping () -> Void) -> some View {
        modifier(UnsavedChangesGuard(isDirty: isDirty, canSave: canSave, confirming: confirming, message: message, save: save))
    }
}
