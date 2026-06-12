import SwiftUI

@main
struct GloamVoiceStudioApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Migrate from gloam-voice-engine…") {
                    NotificationCenter.default.post(name: .gloamMigrate, object: nil)
                }
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
