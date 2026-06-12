import Foundation
import Observation
import SpeechKit
import WhisperKit

/// Download/state manager for Whisper STT models, keyed by catalog variant.
/// Mirrors ModelDownloadManager (which is keyed by TTS BackendID).
@MainActor @Observable
final class WhisperModelManager {
    enum State: Equatable {
        case notDownloaded, downloading(Double), ready, failed(String)
    }

    let root: URL   // StoragePaths.models/whisper
    let uiTest: Bool
    private(set) var states: [String: State] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(root: URL, uiTest: Bool) {
        self.root = root
        self.uiTest = uiTest
        refresh()
    }

    func state(for variant: String) -> State {
        uiTest ? .ready : (states[variant] ?? .notDownloaded)
    }

    func directory(for variant: String) -> URL {
        root.appendingPathComponent(variant)
    }

    func refresh() {
        for model in WhisperModelCatalog.models {
            if case .downloading = states[model.variant] { continue }
            let dir = directory(for: model.variant)
            let hasContents = ((try? FileManager.default
                .contentsOfDirectory(atPath: dir.path))?.isEmpty == false)
            states[model.variant] = hasContents ? .ready : .notDownloaded
        }
    }

    func download(_ variant: String) {
        if case .downloading = states[variant] { return }
        states[variant] = .downloading(0)
        downloadTasks[variant] = Task {
            do {
                let folder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: self.root,
                    from: WhisperModelCatalog.repo,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  case .downloading = self.states[variant] else { return }
                            self.states[variant] = .downloading(progress.fractionCompleted)
                        }
                    })
                // WhisperKit returns early (partial folder) on cancel
                // rather than throwing — never mark that .ready.
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: folder)
                    self.states[variant] = .notDownloaded
                    self.downloadTasks[variant] = nil
                    return
                }
                let want = self.directory(for: variant)
                if folder.standardizedFileURL != want.standardizedFileURL {
                    try? FileManager.default.createDirectory(
                        at: want.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: want)
                    try FileManager.default.moveItem(at: folder, to: want)
                }
                // Drop the HF cache tree WhisperKit leaves under root.
                try? FileManager.default.removeItem(
                    at: self.root.appendingPathComponent("models"))
                self.states[variant] = .ready
            } catch is CancellationError {
                self.states[variant] = .notDownloaded
            } catch {
                self.states[variant] = .failed(error.localizedDescription)
            }
            self.downloadTasks[variant] = nil
        }
    }

    func cancelDownload(_ variant: String) {
        downloadTasks[variant]?.cancel()
    }

    func delete(_ variant: String) {
        downloadTasks[variant]?.cancel()
        try? FileManager.default.removeItem(at: directory(for: variant))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("models"))
        states[variant] = .notDownloaded
    }
}
