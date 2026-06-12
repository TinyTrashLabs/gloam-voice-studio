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
                TranscribeMenuButton()
                Button("Migrate from gloam-voice-engine…") {
                    NotificationCenter.default.post(name: .gloamMigrate, object: nil)
                }
            }
        }
        Window("Transcribe Audio", id: "transcribe") {
            TranscribeWindow()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}

private struct TranscribeMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Transcribe Audio…") { openWindow(id: "transcribe") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}
