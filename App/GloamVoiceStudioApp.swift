import SwiftUI

struct GloamVoiceStudioApp: App {
    @State private var model = AppModel()
    // Only reason for a delegate: `application(_:open:)` is how Launch Services
    // hands over a double-clicked / AirDropped .gvoice pack.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // In UI-test mode, reset persisted UI state so tests start from a clean
        // known state regardless of what previous runs left behind.
        if UITestMode.isActive {
            UserDefaults.standard.removeObject(forKey: "studioMode")
            UserDefaults.standard.removeObject(forKey: "studioSection")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .preferredColorScheme(.dark)
                // Empty the window title — the GLOAM.FM lockup in the sidebar is
                // the brand, so the OS title text is redundant. (navigationTitle
                // empties the text but keeps the titlebar layout, so the toolbar
                // stays on the right; .windowStyle(.hiddenTitleBar) would shove
                // the toolbar to the leading edge.)
                .navigationTitle("")
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                TranscribeMenuButton()
                #if DEBUG
                Button("Migrate from gloam-voice-engine…") {
                    NotificationCenter.default.post(name: .gloamMigrate, object: nil)
                }
                #endif
            }
            // View → section switching, mirroring the toolbar scope control.
            CommandGroup(before: .toolbar) {
                SectionMenuButtons()
                Divider()
            }
            CommandGroup(replacing: .help) {
                DocsMenuButton()
                Link("Documentation on GitHub",
                     destination: URL(string:
                        "https://github.com/TinyTrashLabs/gloam-voice-studio/tree/main/docs")!)
            }
        }
        Window("Transcribe Audio", id: "transcribe") {
            TranscribeWindow()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        Window("Documentation", id: "docs") {
            DocsWindow()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 900, height: 640)
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// View-menu items for the three main sections (⌘1/⌘2/⌘3). Writes the same
/// AppStorage key the toolbar picker reads, so the two stay in lockstep.
private struct SectionMenuButtons: View {
    @AppStorage("studioSection") private var sectionRaw = StudioSection.studio.rawValue
    var body: some View {
        Button("Studio") { sectionRaw = StudioSection.studio.rawValue }
            .keyboardShortcut("1", modifiers: .command)
        Button("Create Voice") { sectionRaw = StudioSection.createVoice.rawValue }
            .keyboardShortcut("2", modifiers: .command)
        Button("Chat") { sectionRaw = StudioSection.chat.rawValue }
            .keyboardShortcut("3", modifiers: .command)
    }
}

private struct TranscribeMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Transcribe Audio…") { openWindow(id: "transcribe") }
            .keyboardShortcut("t", modifiers: [.command, .shift])
    }
}

private struct DocsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Gloam Documentation") { openWindow(id: "docs") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
