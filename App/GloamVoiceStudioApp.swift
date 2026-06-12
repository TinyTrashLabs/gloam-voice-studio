import SwiftUI

@main
struct GloamVoiceStudioApp: App {
    @State private var model = AppModel()

    init() {
        // In UI-test mode, reset persisted UI state so tests start from a clean
        // known state regardless of what previous runs left behind.
        if UITestMode.isActive {
            UserDefaults.standard.removeObject(forKey: "studioMode")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(.dark)
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
