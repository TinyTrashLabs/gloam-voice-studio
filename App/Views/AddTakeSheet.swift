import AVFAudio
import AVFoundation
import Combine
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

/// Adds one take to a voice from a clip the user records or imports, with the words it says: a new
/// language's natural take, another language's acted take (`es-excited`), or a home-language style
/// for a voice whose home isn't English (the guided passage is English). The transcript is required,
/// in the take's own language, because every clone engine conditions on it.
struct AddTakeSheet: View {
    let baseSlug: String
    let baseName: String
    let target: AddTakeTarget
    /// The voice's home language (normalized tag), nil when unstated.
    let homeLanguage: String?
    /// Languages the voice already has a row for; adding one of them again replaces its take.
    var existingLanguages: Set<String> = []
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var language = "es"
    @State private var otherLanguage = ""
    @State private var clip: Data?
    @State private var clipDesc = "No clip yet"
    @State private var transcript = ""
    @State private var importing = false
    @State private var recorder: AVAudioRecorder?
    @State private var recordURL: URL?
    @State private var startedAt: Date?
    @State private var tick = Date()
    @State private var error: String?
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private static let other = "other"

    /// The language this take speaks, as a tag; nil = the home language.
    private var takeLanguage: String? {
        if target.newLanguage {
            let tag = language == Self.other ? otherLanguage : language
            return tag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return target.language
    }

    private var languageName: String {
        takeLanguage.map(VoiceTakesPanel.languageName) ?? VoiceTakesPanel.languageName(homeLanguage)
    }

    private var title: String {
        if target.newLanguage { return "Add a language" }
        let style = target.style.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() } ?? "Natural"
        return "\(languageName) — \(style) take"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            (Text(target.newLanguage ? "Another language for " : "A take of ").font(.callout).foregroundStyle(.secondary)
                + Text(baseName).font(.callout.weight(.bold)).foregroundStyle(Brand.accent)
                + Text(" — a clip of this voice speaking \(target.newLanguage ? "that language" : languageName)"
                       + (target.style.map { ", delivered \($0.name)" } ?? "") + ", and what it says.")
                    .font(.callout).foregroundStyle(.secondary))

            if target.newLanguage { languagePicker }

            HStack(spacing: 10) {
                if isRecording {
                    Text(String(format: "%.0f s", tick.timeIntervalSince(startedAt!)))
                        .font(.system(.body, design: .monospaced))
                        .onReceive(timer) { tick = $0 }
                    Button("Stop") { stopRecording() }.accessibilityIdentifier("add-take-stop")
                } else {
                    Button { startRecording() } label: { Label("Record", systemImage: "mic.fill") }
                        .accessibilityIdentifier("add-take-record")
                    Button("Choose clip…") { importing = true }.accessibilityIdentifier("add-take-import")
                    if UITestMode.isActive {
                        Button("Use Sample Reference") { setClip(UITestMode.sampleReference(), "Sample reference") }
                            .accessibilityIdentifier("add-take-sample")
                    }
                }
                Text(clipDesc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript — exactly what the clip says, in \(languageName)")
                    .font(.caption2).foregroundStyle(.secondary)
                TextEditor(text: $transcript)
                    .font(.callout).scrollContentBackground(.hidden)
                    .frame(minHeight: 70)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))
                    .accessibilityIdentifier("add-take-transcript")
            }

            if let error { Text(error).foregroundStyle(.orange).font(.caption) }

            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                Button("Add take") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(clip == nil || isRecording
                              || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("add-take-save")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // Start on a language the voice doesn't speak yet.
            language = VoiceLanguages.common.first { $0 != homeLanguage && !existingLanguages.contains($0) }
                ?? Self.other
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .wav, .mpeg4Audio],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try RefAudioValidator.validate(url: url)
                setClip(try Data(contentsOf: url), url.lastPathComponent, imported: true)
            } catch { self.error = model.describeAny(error) }
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 8) {
            Text("Language").font(.caption).foregroundStyle(Brand.fgDim)
            Picker("", selection: $language) {
                ForEach(VoiceLanguages.common.filter { $0 != homeLanguage }, id: \.self) {
                    Text(VoiceTakesPanel.languageName($0) + (existingLanguages.contains($0) ? " (replace)" : ""))
                        .tag($0)
                }
                Text("Other…").tag(Self.other)
            }
            .labelsHidden().frame(width: 170)
            .accessibilityIdentifier("add-take-language")
            if language == Self.other {
                TextField("BCP-47 tag, e.g. pt-BR", text: $otherLanguage)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
            }
        }
    }

    // MARK: - Clip

    @State private var clipImported = false
    private var isRecording: Bool { startedAt != nil }

    private func setClip(_ data: Data, _ desc: String, imported: Bool = false) {
        clip = data
        clipDesc = desc
        clipImported = imported
        error = nil
    }

    private func startRecording() {
        error = nil
        AVCaptureDeviceRequestBridge.requestMicAccess { granted in
            guard granted else { error = "Microphone access was denied."; return }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gloam-take-rec-\(UUID().uuidString).wav")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.record()
                recorder = rec
                recordURL = url
                startedAt = Date()
                tick = Date()
            } catch { self.error = model.describeAny(error) }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        guard let recordURL else { return }
        defer { try? FileManager.default.removeItem(at: recordURL) }
        do {
            try RefAudioValidator.validate(url: recordURL)
            setClip(try Data(contentsOf: recordURL), String(format: "Recorded %.0f s", seconds))
        } catch { self.error = model.describeAny(error) }
    }

    private func cancel() {
        recorder?.stop()
        recorder = nil
        startedAt = nil
        if let recordURL { try? FileManager.default.removeItem(at: recordURL) }
        dismiss()
    }

    // MARK: - Save

    private func save() {
        guard let clip else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let provenance = VoiceLibrary.takeProvenance(origin: clipImported ? "imported" : "recorded")
        do {
            if let language = takeLanguage {
                guard let key = VoiceLibrary.languageKey(language) else {
                    error = "“\(language)” isn't a language tag (e.g. es, fr, pt-BR)."; return
                }
                if target.newLanguage, key == homeLanguage {
                    error = "That's this voice's home language — its natural take is the reference clip."
                    return
                }
                try model.voices.addLanguageTake(baseSlug, language: language, style: target.style,
                                                 refWav: clip, refText: text, provenance: provenance)
            } else if let style = target.style {
                try model.voices.addStyleTake(baseSlug, style: style, refWav: clip, refText: text,
                                              provenance: provenance)
            } else {
                return
            }
            model.voicesVersion += 1
            onSaved()
            dismiss()
        } catch { self.error = model.describeAny(error) }
    }
}

/// Common BCP-47 tags offered by the language pickers; anything else can be typed.
enum VoiceLanguages {
    static let common = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "pl", "ru", "tr", "ar", "hi",
                         "ja", "ko", "zh"]
}
