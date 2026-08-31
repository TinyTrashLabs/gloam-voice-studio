import Foundation
import os

/// All app data lives inside the sandbox container, per the design spec.
public enum StoragePaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// App Group shared by every Gloam app on the Mac. macOS requires the
    /// identifier to begin with the Team ID (iOS's bare `group.` prefix is
    /// rejected here) -- see `com.apple.security.application-groups`.
    public static let appGroupID = "UT233385J9.fm.gloam"

    private static let log = Logger(subsystem: "fm.gloam.enginekit", category: "storage")

    /// True when the App Group container could not be resolved and everything
    /// shared has fallen back to this app's own Application Support. Callers
    /// can surface it; the app is functional but is looking at a private store,
    /// so an existing library of models and voices will appear to be missing.
    public private(set) nonisolated(unsafe) static var isUsingFallbackStore = false

    /// Root for data that is shared between apps. Studio is sandboxed and the
    /// Butler is not, so without the group container they resolve to two
    /// different directories and each downloads its own copy of a 529 MB
    /// engine. Falls back to this app's own Application Support when the
    /// container can't be resolved -- a provisioning problem should cost the
    /// sharing, not the app.
    ///
    /// The fallback is LOUD. An ad-hoc signature carries no Team ID, so the
    /// container silently resolves to nil, and a quiet fallback makes a machine
    /// with 41 GB of models on it look like a fresh install and start
    /// re-downloading all of them. Losing the sharing is acceptable; doing it
    /// without saying so is not.
    public static var shared: URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            if !isUsingFallbackStore {
                isUsingFallbackStore = true
                log.error("""
                    App Group \(appGroupID, privacy: .public) unavailable — falling back to \
                    \(appSupport.path, privacy: .public). Models and voices in the group \
                    container will look missing and may be re-downloaded. Usual cause: the \
                    build is ad-hoc signed (no Team ID) or the entitlement isn't granted.
                    """)
            }
            return appSupport
        }
        isUsingFallbackStore = false
        // macOS creates the container for a sandboxed app, but an unsandboxed
        // member of the group (the Butler) is only handed the path -- the
        // directory may not exist yet.
        try? FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    /// Shared: a voice imported in Studio is speakable by the Butler.
    public static var voices: URL {
        let root = shared.appendingPathComponent("Voices")
        migrate(from: appSupport.appendingPathComponent("Voices"), to: root)
        return root
    }

    /// Private to each app -- one app's conversation log is not the other's.
    public static var history: URL { appSupport.appendingPathComponent("History") }

    /// Private: unsaved Voice Foundry takes, meaningless outside the app that
    /// is auditioning them.
    public static var foundryCandidates: URL {
        appSupport.appendingPathComponent("FoundryCandidates")
    }

    /// Private: rendered chat audio belongs to that app's own transcript.
    public static var chatAudio: URL { appSupport.appendingPathComponent("ChatAudio") }

    /// Shared: the engines are the expensive part (lux-tts alone is 529 MB,
    /// gemma4-e4b 4.8 GB) and there is no reason for two Gloam apps on one Mac
    /// to hold two copies.
    public static var models: URL {
        let root = shared.appendingPathComponent("Models")
        // Caches/ first (macOS may purge it), then this app's own container.
        migrate(from: FileManager.default.urls(for: .cachesDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("Models"), to: root)
        migrate(from: appSupport.appendingPathComponent("Models"), to: root)
        return root
    }

    /// Move a store to its current home, one child at a time.
    ///
    /// Per-child (rather than one `moveItem` on the whole directory) makes an
    /// interrupted prior migration self-healing: a child already present at
    /// `newRoot` is left alone (never overwritten, never deleted), everything
    /// else is moved over, and the old root is removed only once it's empty.
    /// Within a volume each move is a rename, so 41 GB of engines costs no
    /// copying -- but an interrupted run must still be safe, hence per-child.
    static func migrate(from old: URL, to newRoot: URL) {
        let fm = FileManager.default
        guard old.standardizedFileURL != newRoot.standardizedFileURL else { return }
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: newRoot.path) {
            try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        }
        let children = (try? fm.contentsOfDirectory(
            at: old, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let dest = newRoot.appendingPathComponent(child.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.moveItem(at: child, to: dest)
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: old.path), remaining.isEmpty {
            try? fm.removeItem(at: old)
        }
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
