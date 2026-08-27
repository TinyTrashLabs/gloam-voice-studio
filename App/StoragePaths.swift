import Foundation

/// All app data lives inside the sandbox container, per the design spec.
enum StoragePaths {
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var voices: URL { appSupport.appendingPathComponent("Voices") }
    static var history: URL { appSupport.appendingPathComponent("History") }
    static var foundryCandidates: URL { appSupport.appendingPathComponent("FoundryCandidates") }
    static var chatAudio: URL { appSupport.appendingPathComponent("ChatAudio") }
    static var models: URL {
        let newRoot = appSupport.appendingPathComponent("Models")
        migrateLegacyModelsRoot(to: newRoot)
        return newRoot
    }

    /// Models used to live in Caches/, which macOS may purge; merge any
    /// leftovers into Application Support once. Migrating per-child (rather
    /// than one `moveItem` on the whole directory) makes an interrupted
    /// prior migration self-healing: a backend already present at `newRoot`
    /// is left alone (never overwritten, never deleted), everything else is
    /// moved over, and the old root is removed only once it's empty.
    private static func migrateLegacyModelsRoot(to newRoot: URL) {
        let fm = FileManager.default
        let old = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models")
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: newRoot.path) {
            try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        }
        let children = (try? fm.contentsOfDirectory(
            at: old, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let dest = newRoot.appendingPathComponent(child.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            do {
                try fm.moveItem(at: child, to: dest)
            } catch {
                AppLog.storage.error(
                    "legacy model migration failed for \(child.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let remaining = try? fm.contentsOfDirectory(atPath: old.path), remaining.isEmpty {
            try? fm.removeItem(at: old)
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
