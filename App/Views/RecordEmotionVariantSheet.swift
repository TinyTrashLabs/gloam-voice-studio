import EngineKit
import StudioKit
import SwiftUI

/// Guided two-step flow for recording an acted `<base>-<emotion>` variant:
/// a Prepare step (fixed script, emotion-specific delivery note, recording
/// tips), then the standard `RecorderView`. Saves directly under the derived
/// slug — no name/avatar/multi-clip apparatus, and no transcription step,
/// since the transcript is the fixed passage.
struct RecordEmotionVariantSheet: View {
    let baseSlug: String
    let baseName: String
    let emotion: Emotion
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var showRecorder = false
    @State private var error: String?

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

            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("record-variant-cancel")
                if UITestMode.isActive {
                    Button("Use Sample Reference") {
                        saveTake(UITestMode.sampleReference())
                    }
                    // Distinct from the form's "use-sample-ref": the Create Voice
                    // page's recording form can be on screen behind this sheet.
                    .accessibilityIdentifier("record-variant-sample")
                }
                Button("Start Recording") { showRecorder = true }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("record-variant-start")
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(isPresented: $showRecorder) {
            RecorderView { data, _ in saveTake(data) }
        }
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
