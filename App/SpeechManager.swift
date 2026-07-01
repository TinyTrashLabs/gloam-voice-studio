import Foundation
import Observation
import SpeechKit

/// App-level speech facade: which engine the user picked, transcriber
/// construction, and Whisper model state. Owned by AppModel.
@MainActor @Observable
final class SpeechManager {
    enum EngineChoice: String, CaseIterable {
        case apple, whisper
        var label: String {
            switch self {
            case .apple: "Apple (built-in, on-device)"
            case .whisper: "Whisper (downloadable, on-device)"
            }
        }
    }

    let whisperModels: WhisperModelManager

    var engineChoice: EngineChoice {
        didSet { UserDefaults.standard.set(engineChoice.rawValue,
                                           forKey: "speechEngine") }
    }
    var whisperVariant: String {
        didSet { UserDefaults.standard.set(whisperVariant,
                                           forKey: "speechWhisperVariant") }
    }
    var languageHint: String {
        didSet { UserDefaults.standard.set(languageHint,
                                           forKey: "speechLanguageHint") }
    }

    init(uiTest: Bool) {
        let defaults = UserDefaults.standard
        whisperModels = WhisperModelManager(
            root: StoragePaths.models.appendingPathComponent("whisper"),
            uiTest: uiTest)
        engineChoice = EngineChoice(
            rawValue: defaults.string(forKey: "speechEngine") ?? "") ?? .apple
        whisperVariant = defaults.string(forKey: "speechWhisperVariant")
            ?? WhisperModelCatalog.defaultVariant
        languageHint = defaults.string(forKey: "speechLanguageHint") ?? ""
    }

    var effectiveLanguageHint: String? {
        languageHint.isEmpty ? nil : languageHint
    }

    /// True when the chosen whisper model can actually run right now.
    var whisperReady: Bool {
        whisperModels.state(for: whisperVariant) == .ready
    }

    /// Build a transcriber for the current choice. Falls back to Apple when
    /// Whisper is selected but its model isn't downloaded.
    func makeTranscriber() -> any Transcriber {
        if UITestMode.isActive { return FakeTranscriber() }
        switch engineChoice {
        case .whisper where whisperReady:
            return WhisperTranscriber(
                modelFolder: whisperModels.directory(for: whisperVariant))
        case .whisper, .apple:
            return AppleTranscriber(
                locale: effectiveLanguageHint.map(Locale.init(identifier:))
                    ?? .current)
        }
    }

    /// Ask for speech-recognition permission when the Apple engine will run.
    func ensureAuthorized() async -> Bool {
        if UITestMode.isActive { return true }
        if engineChoice == .whisper && whisperReady { return true }
        return await AppleTranscriber.requestAuthorization()
    }
}
