import Foundation

/// `--serve [--port N]` launches the signed app as a windowless local API
/// daemon — no Dock icon, no window — so an agent can talk to the studio's
/// native STT/TTS with no GUI running. Same signed bundle identity as the
/// GUI, so mic/Speech-Recognition TCC grants (from a prior GUI launch) carry
/// over. Mirrors `UITestMode`'s ProcessInfo-flag pattern.
enum HeadlessMode {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--serve") }

    /// The integer after `--port`, if present and parseable.
    static var requestedPort: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "--port"), flagIndex + 1 < args.count else {
            return nil
        }
        return Int(args[flagIndex + 1])
    }
}
