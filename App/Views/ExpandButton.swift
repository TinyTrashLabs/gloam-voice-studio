import StudioKit
import SwiftUI

/// A reusable "Expand" affordance for prompt-like text fields: sends the
/// field's current text through the user's chosen chat LLM to get a fuller
/// version, replaces the field's text with the result, and offers one-level
/// undo.
struct ExpandButton: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    let kind: PromptExpansionKind

    @State private var isExpanding = false
    @State private var undoText: String?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                Task { await expand() }
            } label: {
                if isExpanding {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Expand", systemImage: "sparkles")
                }
            }
            .disabled(isExpanding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Use \(model.chatLLM.rawValue) to expand this into a fuller \(kind.noun).")

            if let undoText {
                Button("Undo") {
                    text = undoText
                    self.undoText = nil
                }
                .font(.caption2)
            }
        }
        .onChange(of: text) { _, _ in
            if !isExpanding { undoText = nil }
        }
        .alert("Couldn't expand", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func expand() async {
        isExpanding = true
        defer { isExpanding = false }
        do {
            let expanded = try await model.expand(text, kind: kind)
            undoText = text
            text = expanded
        } catch {
            errorMessage = model.describeAny(error)
        }
    }
}
