import AppKit
import SwiftUI

/// The `--serve` entry point: the same signed bundle, launched with no
/// window and no Dock icon, running only the loopback API server. A separate
/// `App` type (rather than an `if`/`else` inside `GloamVoiceStudioApp.body`)
/// because `SceneBuilder`, unlike `ViewBuilder`, doesn't support conditional
/// branches — `main.swift` picks which of these two `App` types to run.
struct HeadlessVoiceStudioApp: App {
    @State private var model = AppModel()

    /// Retains the signal-monitoring dispatch sources for the process
    /// lifetime — a local `let` would be freed (and stop firing) as soon as
    /// `init()` returns.
    private static var signalSources: [DispatchSourceSignal] = []

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = model
        Task {
            let defaultPort = await model.serverPort
            let port = HeadlessMode.requestedPort ?? defaultPort
            let authorized = await model.speech.ensureAuthorized()
            let sttStatus = authorized
                ? "authorized (native on-device)"
                : "NOT authorized — launch the GUI once to grant Speech Recognition, or listen/transcribe will error"
            FileHandle.standardError.write(Data("[studio] --serve: STT \(sttStatus)\n".utf8))
            await model.startHeadlessServer(port: port)
            FileHandle.standardError.write(Data(
                "[studio] --serve: listening on 127.0.0.1:\(port)\n".utf8))
        }
        Self.installShutdownHandlers(model: model)
    }

    /// SIGINT/SIGTERM → stop the server cleanly, then exit. Without this the
    /// process still dies on the signal's default disposition, leaving the
    /// Hummingbird listener's shutdown (and any in-flight `listen` mic
    /// capture) unresolved instead of tearing down in order.
    private static func installShutdownHandlers(model: AppModel) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    await model.shutdownForExit()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    var body: some Scene {
        // Settings scenes never auto-open a window at launch (unlike
        // WindowGroup), so this keeps the process alive with nothing visible
        // on screen.
        Settings { EmptyView() }
    }
}
