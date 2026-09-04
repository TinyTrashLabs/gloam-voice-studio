import AppKit
import Observation
import SwiftUI

/// Receives `.gvoice` files opened through Launch Services — double-click,
/// Open With, or an AirDrop the user accepted — and installs them.
///
/// Opening a file can LAUNCH the app, in which case AppKit calls
/// `application(_:open:)` before any scene exists and before `AppModel` has
/// been built. Dropping those URLs would make the very first AirDrop of a
/// session silently do nothing, so they queue here until a view attaches the
/// model and drains them.
@MainActor @Observable
final class PackOpenHandler {
    static let shared = PackOpenHandler()

    /// Set once the first scene appears. Nil while the app is still launching.
    private var model: AppModel?
    private var pending: [URL] = []

    /// Failures from the most recent open, for the sidebar to surface. The
    /// sidebar clears it once shown.
    var openError: String?

    private init() {}

    func open(_ urls: [URL]) {
        pending.append(contentsOf: urls)
        drain()
    }

    /// Called by the sidebar once it has the model in hand.
    func attach(_ model: AppModel) {
        self.model = model
        drain()
    }

    private func drain() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        let failures = model.importPacks(from: urls)
        if !failures.isEmpty { openError = failures.joined(separator: "\n") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI owns the model, while AppKit owns the termination handshake.
    /// The app installs this closure once its scene exists so Cmd-Q can wait
    /// for in-flight Metal work before the process starts destroying models.
    var shutdown: (() async -> Void)?
    private var terminationPending = false

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { PackOpenHandler.shared.open(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
