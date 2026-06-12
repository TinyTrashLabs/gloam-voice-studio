import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Text("History")
            Button("Done") { dismiss() }
        }
        .padding(40)
        .frame(width: 400, height: 200)
    }
}
