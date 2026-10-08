import Foundation

/// Where a Neural Engine model set lives on disk: `qwen3-0.6b-ane` or `qwen3-1.7b-ane`.
///
/// A set (talker chunks, cp_ane, upF, upMall, the two voice encoders as `.mlmodelc`, plus `host/` and
/// `vochead/`; see Sources/QwenANE/README.md) is published as `tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE` /
/// `tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE`, and the in-app downloader fetches it into `defaultDirectory`. It is
/// resolved, first match wins, from:
///
///  1. the set's environment variable (`GLOAM_QWEN_ANE_MODELS`, `GLOAM_QWEN_ANE_17B_MODELS`; a models directory),
///  2. the set's UserDefaults key (`defaults write <bundle id> qwenANEModelsPath <dir>`, `qwenANE17BModelsPath`),
///  3. the App Group's shared `Models/qwen3-0.6b-ane/` (`qwen3-1.7b-ane`), beside the MLX models (`StoragePaths.models`);
///  4. the old per-app `<Application Support>/GloamVoiceStudio/Models/<set>/`, read for existing installs.
///
/// A directory only counts when it holds the whole set, so a half-copied folder is reported as such.
public struct QwenANEModelSet: Sendable, Equatable {
    public let backend: BackendID
    public let folderName: String
    public let environmentKey: String
    public let defaultsKey: String
    /// Compiled models the engine and the voice-prep step load, relative to the models directory.
    public let requiredFiles: [String]

    private static let shared = [
        "host/config.json", "host/tokenizer.json", "vochead",
        "coreml/cp_ane.mlmodelc", "coreml/upMall.mlmodelc", "coreml/upF.mlmodelc",
        "coreml/QwenSpeechEncoder.mlmodelc", "coreml/QwenSpeakerEncoder.mlmodelc",
    ]

    public static let qwen06 = QwenANEModelSet(
        backend: .qwen06BANE, folderName: "qwen3-0.6b-ane",
        environmentKey: "GLOAM_QWEN_ANE_MODELS", defaultsKey: "qwenANEModelsPath",
        requiredFiles: shared + ["coreml/talker0.mlmodelc", "coreml/talker1.mlmodelc"])

    public static let qwen17 = QwenANEModelSet(
        backend: .qwen17BANE, folderName: "qwen3-1.7b-ane",
        environmentKey: "GLOAM_QWEN_ANE_17B_MODELS", defaultsKey: "qwenANE17BModelsPath",
        requiredFiles: shared + (0..<4).map { "coreml/talker\($0).mlmodelc" } + ["host/cp_in_proj_w.npy", "host/cp_in_proj_b.npy"])

    public static let all = [qwen06, qwen17]

    /// The set a Neural Engine backend loads; nil for any other backend.
    public static func of(_ backend: BackendID) -> QwenANEModelSet? { all.first { $0.backend == backend } }

    /// Where the set is installed: the App Group's shared Models folder, beside the MLX models, so Studio,
    /// the radio and the Butler read ONE copy (2026-10-08; it used to be each app's own Application Support).
    public func defaultDirectory(models: URL = StoragePaths.models) -> URL {
        models.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The pre-2026-10-08 per-app location, still read so an existing install keeps working.
    public func legacyDirectory(appSupport: URL = StoragePaths.appSupport) -> URL {
        appSupport.appendingPathComponent("GloamVoiceStudio/Models/\(folderName)", isDirectory: true)
    }

    /// The per-voice prep cache of this set (a prepared voice's speaker embedding is the size's own).
    public func defaultCacheRoot(appSupport: URL = StoragePaths.appSupport) -> URL {
        appSupport.appendingPathComponent("GloamVoiceStudio/Cache/\(folderName)", isDirectory: true)
    }

    /// Candidate directories in resolution order.
    public func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                           defaults: UserDefaults = .standard,
                           appSupport: URL = StoragePaths.appSupport,
                           models: URL = StoragePaths.models) -> [URL] {
        var out: [URL] = []
        if let p = environment[environmentKey], !p.isEmpty {
            out.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let p = defaults.string(forKey: defaultsKey), !p.isEmpty {
            out.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
        }
        out.append(defaultDirectory(models: models))
        out.append(legacyDirectory(appSupport: appSupport))
        return out
    }

    /// The first required entry missing from `directory`, or nil when the set is complete.
    public func missingEntry(in directory: URL) -> String? {
        requiredFiles.first { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// The models directory, or `EngineError.modelNotInstalled` naming every place that was looked at.
    public func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard,
                        appSupport: URL = StoragePaths.appSupport,
                        models: URL = StoragePaths.models) throws -> URL {
        let all = candidates(environment: environment, defaults: defaults, appSupport: appSupport, models: models)
        var notes: [String] = []
        for dir in all {
            guard let missing = missingEntry(in: dir) else { return dir }
            notes.append("\(dir.path) (missing \(missing))")
        }
        throw EngineError.modelNotInstalled(
            backend: backend,
            detail: "the Neural Engine model set was not found. Expected at "
                + defaultDirectory(models: models).path
                + ", or set \(environmentKey) / the \(defaultsKey) default to a models directory. Looked at: "
                + notes.joined(separator: "; ") + ".")
    }
}

/// The `qwen3-0.6b-ane` set's location (the original API; `QwenANEModelSet` is the size-generic form).
public enum QwenANEModelLocation {
    public static let environmentKey = QwenANEModelSet.qwen06.environmentKey
    public static let defaultsKey = QwenANEModelSet.qwen06.defaultsKey
    public static let folderName = QwenANEModelSet.qwen06.folderName
    static let requiredFiles = QwenANEModelSet.qwen06.requiredFiles

    public static func defaultDirectory(models: URL = StoragePaths.models) -> URL {
        QwenANEModelSet.qwen06.defaultDirectory(models: models)
    }

    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  defaults: UserDefaults = .standard,
                                  appSupport: URL = StoragePaths.appSupport,
                                  models: URL = StoragePaths.models) -> [URL] {
        QwenANEModelSet.qwen06.candidates(environment: environment, defaults: defaults, appSupport: appSupport, models: models)
    }

    public static func missingEntry(in directory: URL) -> String? { QwenANEModelSet.qwen06.missingEntry(in: directory) }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard,
                               appSupport: URL = StoragePaths.appSupport,
                               models: URL = StoragePaths.models) throws -> URL {
        try QwenANEModelSet.qwen06.resolve(environment: environment, defaults: defaults, appSupport: appSupport, models: models)
    }
}
