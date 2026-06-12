import SwiftUI

/// Mic toggle for any text field. Appends dictated text to the bound string.
struct DictationButton: View {
    @Binding var text: String
    @Environment(AppModel.self) private var model
    @State private var controller = DictationController()

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                controller.toggle(
                    speech: model.speech,
                    getText: { text },
                    setText: { text = $0 })
            } label: {
                Image(systemName: controller.isActive ? "mic.fill" : "mic")
                    .foregroundStyle(controller.isActive ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: controller.isActive)
            }
            .help(controller.isActive ? "Stop dictation" : "Dictate")
            .accessibilityIdentifier("dictate")
            if controller.isProcessing {
                ProgressView().controlSize(.mini)
                    .help("Transcribing…")
            }
            if let message = controller.errorMessage {
                Text(message).font(.caption2).foregroundStyle(.red)
            }
        }
    }
}
