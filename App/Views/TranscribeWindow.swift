import SpeechKit
import SwiftUI
import UniformTypeIdentifiers

/// Drop audio → text. Uses whichever engine is selected in Settings → Speech.
struct TranscribeWindow: View {
    @Environment(AppModel.self) private var model
    @State private var resultText = ""
    @State private var status = "Drop an audio file here, or choose one."
    @State private var working = false
    @State private var importerShown = false
    @State private var transcribeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(spacing: 8) {
                    Text(status).font(.callout)
                    HStack {
                        Button("Choose File…") { importerShown = true }
                            .accessibilityIdentifier("transcribe-choose")
                        if working { ProgressView().controlSize(.small) }
                        if UITestMode.isActive {
                            Button("Use Sample Audio") {
                                transcribe(data: UITestMode.sampleReference())
                            }
                            .accessibilityIdentifier("transcribe-sample")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(10)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in transcribe(url: url) }
                }
                return true
            }

            TextEditor(text: $resultText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityIdentifier("transcribe-result")

            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resultText, forType: .string)
                }
                .disabled(resultText.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
        .fileImporter(isPresented: $importerShown,
                      allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { transcribe(url: url) }
        }
    }

    private func transcribe(url: URL) {
        status = url.lastPathComponent
        run { transcriber, hint in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await transcriber.transcribe(audioURL: url, languageHint: hint)
        }
    }

    private func transcribe(data: Data) {
        run { transcriber, hint in
            try await transcriber.transcribe(wavData: data, languageHint: hint)
        }
    }

    private func run(_ work: @escaping (any Transcriber, String?) async throws -> Transcript) {
        transcribeTask?.cancel()
        working = true
        transcribeTask = Task { @MainActor in
            defer { if !Task.isCancelled { working = false } }
            guard await model.speech.ensureAuthorized() else {
                status = "Speech permission denied."
                return
            }
            do {
                let transcript = try await work(model.speech.makeTranscriber(),
                                                model.speech.effectiveLanguageHint)
                guard !Task.isCancelled else { return }
                resultText = transcript.text
                status = "Done."
            } catch is CancellationError {
                // superseded by a newer transcription
            } catch {
                guard !Task.isCancelled else { return }
                status = model.describeAny(error)
            }
        }
    }
}
