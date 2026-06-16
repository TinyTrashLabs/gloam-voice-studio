import SwiftUI

/// Structured helper for Qwen3-TTS Voice Design / CustomVoice instructs. Fills in
/// the labeled attributes Qwen recommends (gender, pitch, speed, …) and assembles
/// them into the canonical `key: value.` attribute-list format, writing the result
/// into the Direction box. One-way: build → Apply (the Direction text stays the
/// source of truth, so you can still hand-edit or save it as a preset).
struct VoiceDesignBuilder: View {
    @Binding var instruct: String

    @State private var confirmReplace = false
    @State private var gender = ""
    @State private var pitch = ""
    @State private var speed = ""
    @State private var volume = ""
    @State private var age = ""
    @State private var clarity = ""
    @State private var fluency = ""
    @State private var accent = ""
    @State private var texture = ""
    @State private var emotion = ""
    @State private var tone = ""
    @State private var personality = ""

    /// (label, binding, example placeholder) — label is the exact key Qwen expects.
    private var rows: [(String, Binding<String>, String)] {
        [
            ("gender", $gender, "Male / female / gender-neutral"),
            ("pitch", $pitch, "deep low register with upward lifts"),
            ("speed", $speed, "fast, punchy pauses"),
            ("volume", $volume, "loud, near-shouting at peaks"),
            ("age", $age, "early 30s / elderly"),
            ("accent", $accent, "General American / British"),
            ("texture", $texture, "warm, smooth, low rumble"),
            ("emotion", $emotion, "hyped and electric"),
            ("tone", $tone, "upbeat, performative"),
            ("personality", $personality, "confident, magnetic showman"),
            ("clarity", $clarity, "crisp, distinct (optional)"),
            ("fluency", $fluency, "effortless, no hesitation (optional)"),
        ]
    }

    private func assemble() -> String {
        rows
            .map { ($0.0, $0.1.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)." }
            .joined(separator: "\n")
    }

    private var hasAny: Bool {
        rows.contains { !$0.1.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.0) { label, binding, example in
                    HStack(spacing: 8) {
                        Text(label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Brand.fgDim)
                            .frame(width: 78, alignment: .trailing)
                        TextField(example, text: binding)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                }
                HStack {
                    Spacer()
                    Button("Apply to Direction") {
                        // Don't silently clobber hand-typed Direction text.
                        if instruct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            instruct = assemble()
                        } else {
                            confirmReplace = true
                        }
                    }
                    .disabled(!hasAny)
                    .accessibilityIdentifier("voice-design-apply")
                    .confirmationDialog("Replace the current Direction text?",
                                        isPresented: $confirmReplace) {
                        Button("Replace", role: .destructive) { instruct = assemble() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This overwrites what's currently in the Direction box.")
                    }
                }
                .padding(.top, 2)
            }
            .padding(.top, 6)
        } label: {
            Label("Voice Design builder (Qwen attribute format)",
                  systemImage: "wand.and.stars")
                .font(.caption)
        }
    }
}
