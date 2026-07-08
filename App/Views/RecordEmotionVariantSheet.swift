import AVFAudio
import AVFoundation
import EngineKit
import StudioKit
import SwiftUI

/// Guided recording flow for an acted `<base>-<emotion>` variant: the fixed
/// script, an emotion-specific delivery note, and recording tips stay on
/// screen for the entire flow — recording controls sit inline below them,
/// never in a separate sheet that would cover the passage you're reading.
/// Saves directly under the derived slug — no name/avatar/multi-clip
/// apparatus, and no transcription step, since the transcript is the fixed
/// passage.
struct RecordEmotionVariantSheet: View {
    let baseSlug: String
    let baseName: String
    let emotion: Emotion
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var recorder: AVAudioRecorder?
    @State private var fileURL: URL?
    @State private var startedAt: Date?
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var error: String?

    private var isRecording: Bool { startedAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record — \(emotion.rawValue.capitalized) take")
                .font(.title3.bold())
            (Text("A \(emotion.rawValue) take of ").font(.callout).foregroundStyle(.secondary)
                + Text(baseName).font(.callout.weight(.bold)).foregroundStyle(Brand.accent)
                + Text(" — read the passage below in your own voice, in character.")
                    .font(.callout).foregroundStyle(.secondary))

            Text(RecordingScript.deliveryNote(for: emotion))
                .font(.callout.weight(.semibold))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.accent.opacity(0.12)))

            Text(RecordingScript.passage)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                ForEach(RecordingScript.tips, id: \.self) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("•")
                        Text(tip)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Recording controls stay inline, right below the passage — never a
            // separate sheet, so the script never gets covered while recording.
            HStack {
                if isRecording {
                    Text(String(format: "%.0f s", tick.timeIntervalSince(startedAt!)))
                        .font(.system(.body, design: .monospaced))
                        .onReceive(timer) { tick = $0 }
                }
                Spacer()
                Button("Cancel") { cancel() }
                    .accessibilityIdentifier("record-variant-cancel")
                if UITestMode.isActive && !isRecording {
                    Button("Use Sample Reference") {
                        saveTake(UITestMode.sampleReference())
                    }
                    // Distinct from the form's "use-sample-ref": the Create Voice
                    // page's recording form can be on screen behind this sheet.
                    .accessibilityIdentifier("record-variant-sample")
                }
                if isRecording {
                    Button("Stop & Use") { stopAndSave() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("record-variant-stop")
                } else {
                    Button("Start Recording") { startRecording() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("record-variant-start")
                }
            }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func startRecording() {
        error = nil
        AVCaptureDeviceRequestBridge.requestMicAccess { granted in
            guard granted else { error = "Microphone access was denied."; return }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gloam-variant-rec-\(UUID().uuidString).wav")
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
                fileURL = url
                startedAt = Date()
                tick = Date()
            } catch { self.error = "\(error)" }
        }
    }

    private func stopAndSave() {
        recorder?.stop()
        recorder = nil
        startedAt = nil
        guard let fileURL else { return }
        do {
            _ = try RefAudioValidator.validate(url: fileURL)
            let data = try Data(contentsOf: fileURL)
            try? FileManager.default.removeItem(at: fileURL)
            saveTake(data)
        } catch { self.error = "\(error)" }
    }

    private func cancel() {
        recorder?.stop()
        recorder = nil
        startedAt = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        dismiss()
    }

    private func saveTake(_ data: Data) {
        do {
            let name = "\(baseName)-\(emotion.rawValue)"
            // Re-record: overwrite the existing variant at its known slug.
            if let slug = try? Slug.slugify(name), (try? model.voices.get(slug)) != nil {
                _ = try model.voices.saveAt(slug: slug, name: name,
                                            refWav: data, refText: RecordingScript.passage)
            } else {
                _ = try model.voices.save(name: name, refWav: data,
                                          refText: RecordingScript.passage)
            }
            model.voicesVersion += 1
            onSaved()
            dismiss()
        } catch { self.error = "\(error)" }
    }
}
