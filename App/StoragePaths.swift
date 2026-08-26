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
        // Models used to live in Caches/, which macOS may purge; move once.
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models")
        if FileManager.default.fileExists(atPath: old.path),
           !FileManager.default.fileExists(atPath: newRoot.path) {
            try? FileManager.default.moveItem(at: old, to: newRoot)
        }
        return newRoot
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
