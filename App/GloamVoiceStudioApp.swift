import SwiftUI

@main
struct GloamVoiceStudioApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Text("GLOAM.FM — Voice Studio")
                .font(.system(.title, design: .monospaced))
                .frame(minWidth: 900, minHeight: 600)
                .environment(model)
        }
    }
}
