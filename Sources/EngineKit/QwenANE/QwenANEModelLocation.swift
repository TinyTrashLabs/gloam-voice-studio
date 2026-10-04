import Foundation

/// Where the `qwen3-0.6b-ane` model set lives on disk.
///
/// The set (talker0/1, cp_ane, upF, upMall, the two voice encoders as `.mlmodelc`, plus `host/` and
/// `vochead/`; see Sources/QwenANE/README.md) is not published on Hugging Face yet, so the in-app downloader
/// cannot fetch it. It is resolved, first match wins, from:
///
///  1. the `GLOAM_QWEN_ANE_MODELS` environment variable (a models directory),
///  2. the `qwenANEModelsPath` UserDefaults key (`defaults write <bundle id> qwenANEModelsPath <dir>`),
///  3. `<Application Support>/GloamVoiceStudio/Models/qwen3-0.6b-ane/`.
///
/// A directory only counts when it holds the whole set, so a half-copied folder is reported as such.
public enum QwenANEModelLocation {
    public static let environmentKey = "GLOAM_QWEN_ANE_MODELS"
    public static let defaultsKey = "qwenANEModelsPath"
    public static let folderName = "qwen3-0.6b-ane"

    /// Compiled models the engine and the voice-prep step load, relative to the models directory.
    static let requiredFiles = [
        "host/config.json", "host/tokenizer.json", "vochead",
        "coreml/talker0.mlmodelc", "coreml/talker1.mlmodelc", "coreml/cp_ane.mlmodelc",
        "coreml/upMall.mlmodelc", "coreml/upF.mlmodelc",
        "coreml/QwenSpeechEncoder.mlmodelc", "coreml/QwenSpeakerEncoder.mlmodelc",
    ]

    public static func defaultDirectory(appSupport: URL = StoragePaths.appSupport) -> URL {
        appSupport.appendingPathComponent("GloamVoiceStudio/Models/\(folderName)", isDirectory: true)
    }

    /// Candidate directories in resolution order.
    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  defaults: UserDefaults = .standard,
                                  appSupport: URL = StoragePaths.appSupport) -> [URL] {
        var out: [URL] = []
        if let p = environment[environmentKey], !p.isEmpty {
            out.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let p = defaults.string(forKey: defaultsKey), !p.isEmpty {
            out.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
        }
        out.append(defaultDirectory(appSupport: appSupport))
        return out
    }

    /// The first required entry missing from `directory`, or nil when the set is complete.
    public static func missingEntry(in directory: URL) -> String? {
        requiredFiles.first { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// The models directory, or `EngineError.modelNotInstalled` naming every place that was looked at.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard,
                               appSupport: URL = StoragePaths.appSupport) throws -> URL {
        let all = candidates(environment: environment, defaults: defaults, appSupport: appSupport)
        var notes: [String] = []
        for dir in all {
            guard let missing = missingEntry(in: dir) else { return dir }
            notes.append("\(dir.path) (missing \(missing))")
        }
        throw EngineError.modelNotInstalled(
            backend: .qwen06BANE,
            detail: "the Neural Engine model set was not found. Expected at "
                + defaultDirectory(appSupport: appSupport).path
                + ", or set \(environmentKey) / the \(defaultsKey) default to a models directory. Looked at: "
                + notes.joined(separator: "; ") + ".")
    }
}
