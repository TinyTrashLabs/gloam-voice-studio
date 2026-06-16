import Foundation

/// Hardware/disk primitives the aidj shell uses to gate / offer on-device AI.
/// Primitives only — the slider→tier *policy* lives in the app/web layer, not here.
public struct EngineCapabilities: Sendable, Equatable {
    public let isAppleSilicon: Bool
    public let physicalMemoryBytes: UInt64
    public let freeDiskBytes: Int64

    public init(isAppleSilicon: Bool, physicalMemoryBytes: UInt64, freeDiskBytes: Int64) {
        self.isAppleSilicon = isAppleSilicon
        self.physicalMemoryBytes = physicalMemoryBytes
        self.freeDiskBytes = freeDiskBytes
    }

    /// Snapshot of the current machine. Never throws — failures fall back to
    /// conservative defaults. `modelsRoot` defaults to the managed Models dir.
    public static func current(modelsRoot: URL = StoragePaths.models) -> EngineCapabilities {
        EngineCapabilities(
            isAppleSilicon: detectAppleSilicon(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            freeDiskBytes: availableBytes(on: modelsRoot)
        )
    }
}

private func detectAppleSilicon() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { return value == 1 }
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}

/// Free space on the volume that holds (or will hold) `url`. Walks up to the
/// nearest existing ancestor so a not-yet-created Models dir still measures.
private func availableBytes(on url: URL) -> Int64 {
    let fm = FileManager.default
    var dir = url
    while !fm.fileExists(atPath: dir.path) && dir.pathComponents.count > 1 {
        dir = dir.deletingLastPathComponent()
    }
    let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
}

/// Weights-present check for ANY backend by its on-disk folder name (mirrors
/// ModelDownloadManager's "config.json + a .safetensors" completeness rule), so
/// the shell can gate on a downloaded brain/voice without instantiating the manager.
public func isModelDownloaded(folder: String, in root: URL = StoragePaths.models) -> Bool {
    let dir = root.appendingPathComponent(folder)
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
    let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return contents.contains { $0.pathExtension == "safetensors" }
}
