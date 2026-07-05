import EngineKit
import StudioKit
import SwiftUI

/// Right-hand inspector for the Chat tab — the "LLM stuff exposed" panel:
/// model picker + download/load state, persona editor, sampling essentials,
/// Advanced sampler disclosure with reset, and last-reply stats.
struct ChatInspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var personaDraft = ""
    @State private var greetingDraft = ""
    @State private var advancedOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modelSection
                personaSection
                samplingSection
                advancedSection
                statsSection
            }
            .padding(14)
        }
        .task(id: model.selectedVoiceSlug) { loadPersonaDrafts() }
        .task { await model.refreshEngineStatus() }
    }

    // MARK: model

    private var modelSection: some View {
        @Bindable var appModel = model
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("MODEL")
            Picker("", selection: $appModel.chatLLM) {
                ForEach(LLMBackendID.allCases, id: \.self) { llm in
                    Text(llm.rawValue).tag(llm)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("chat-llm-picker")
            modelStateRow
            Toggle("Speak replies", isOn: $appModel.chatAutoSpeak)
                .toggleStyle(.switch).controlSize(.small)
                .font(.caption).foregroundStyle(Brand.fgDim)
        }
    }

    @ViewBuilder
    private var modelStateRow: some View {
        let llm = model.chatLLM
        let size = ByteCountFormatter.string(fromByteCount: llm.approxBytes,
                                             countStyle: .file)
        switch model.downloads.state(for: llm) {
        case .ready:
            HStack(spacing: 8) {
                Label("On disk", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                if model.loadedLLM == llm {
                    Button("Unload") { Task { await model.unloadChatLLM() } }
                        .font(.caption2)
                        .accessibilityIdentifier("chat-llm-unload")
                }
                Button("Delete") { model.downloads.delete(llm) }
                    .font(.caption2)
                    .accessibilityIdentifier("chat-llm-delete")
            }
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                Button("Cancel") { model.downloads.cancelDownload(llm) }
                    .font(.caption2)
            }
        case .notDownloaded:
            Button("Download (\(size))") { model.downloads.download(llm) }
                .accessibilityIdentifier("chat-llm-download")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(3)
                Button("Retry (\(size))") { model.downloads.download(llm) }
            }
        }
    }

    // MARK: persona

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PERSONA")
            Text("How this voice behaves in chat. Leave blank for a stay-in-character default.")
                .font(.caption2).foregroundStyle(Brand.fgFaint)
            TextEditor(text: $personaDraft)
                .font(.caption)
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                .accessibilityIdentifier("chat-persona-editor")
            TextField("Greeting (optional)", text: $greetingDraft)
                .textFieldStyle(.roundedBorder).font(.caption)
            Button("Save Persona") { savePersona() }
                .font(.caption)
                .disabled(model.selectedVoiceSlug == nil)
        }
    }

    // MARK: sampling essentials

    private var samplingSection: some View {
        @Bindable var chat = model.chat
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("SAMPLING")
            slider("Temperature", value: $chat.sampling.temperature,
                   range: 0...2, format: "%.2f")
            HStack {
                Text("Max tokens").font(.caption).foregroundStyle(Brand.fgDim)
                Spacer()
                TextField("", value: $chat.sampling.maxTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: advanced

    private var advancedSection: some View {
        @Bindable var chat = model.chat
        return DisclosureGroup(isExpanded: $advancedOpen) {
            VStack(alignment: .leading, spacing: 8) {
                slider("Top P", value: $chat.sampling.topP, range: 0.05...1, format: "%.2f")
                intSlider("Top K (0 = off)", value: $chat.sampling.topK, range: 0...200)
                slider("Min P (0 = off)", value: $chat.sampling.minP,
                       range: 0...0.5, format: "%.2f")
                slider("Repetition penalty (0 = off)", value: $chat.sampling.repetitionPenalty,
                       range: 0...2, format: "%.2f")
                slider("Presence penalty (0 = off)", value: $chat.sampling.presencePenalty,
                       range: 0...2, format: "%.2f")
                slider("Frequency penalty (0 = off)", value: $chat.sampling.frequencyPenalty,
                       range: 0...2, format: "%.2f")
                Button("Reset to defaults") { model.chat.resetSampling() }
                    .font(.caption)
                    .accessibilityIdentifier("chat-reset-sampling")
            }
            .padding(.top, 6)
        } label: {
            sectionHeader("ADVANCED")
        }
    }

    // MARK: stats

    @ViewBuilder
    private var statsSection: some View {
        if let stats = model.chat.lastStats {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("LAST REPLY")
                statRow("Speed", stats.tokensPerSecond.map { String(format: "%.1f tok/s", $0) })
                statRow("Prompt", stats.promptTokens.map { "\($0) tok" })
                statRow("Completion", stats.completionTokens.map { "\($0) tok" })
                statRow("Wall time", stats.wallSeconds.map { String(format: "%.2f s", $0) })
            }
        }
    }

    // MARK: helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .heavy)).tracking(1)
            .foregroundStyle(Brand.fgDim)
    }

    private func statRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(Brand.fgFaint)
            Spacer()
            Text(value ?? "—").font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Brand.fgDim)
        }
    }

    private func slider(_ label: String, value: Binding<Float>,
                        range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Brand.fgDim)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.fgFaint)
            }
            Slider(value: value, in: range)
        }
    }

    private func intSlider(_ label: String, value: Binding<Int>,
                           range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Brand.fgDim)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.fgFaint)
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }

    private func loadPersonaDrafts() {
        guard let slug = model.selectedVoiceSlug,
              let meta = try? model.voices.get(slug).meta else {
            personaDraft = ""; greetingDraft = ""
            return
        }
        personaDraft = meta.persona?.systemPrompt ?? ""
        greetingDraft = meta.persona?.greeting ?? ""
    }

    private func savePersona() {
        guard let slug = model.selectedVoiceSlug else { return }
        let prompt = personaDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let greeting = greetingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let persona: Persona? = prompt.isEmpty && greeting.isEmpty
            ? nil
            : Persona(systemPrompt: prompt, greeting: greeting.isEmpty ? nil : greeting)
        try? model.voices.setPersona(slug, persona: persona)
        model.voicesVersion += 1
    }
}
