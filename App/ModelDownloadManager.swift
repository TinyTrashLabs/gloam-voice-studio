import EngineKit
import Foundation
import HuggingFace
import Observation

@MainActor @Observable
final class ModelDownloadManager {
    enum State: Equatable {
        case notDownloaded, downloading(Double), ready, failed(String)
    }

    let root: URL
    let uiTest: Bool
    private(set) var states: [BackendID: State] = [:]
    private var downloadTasks: [BackendID: Task<Void, Never>] = [:]

    /// Approximate full download sizes, for the disk preflight (bytes).
    static let approxBytes: [BackendID: Int64] = [
        .chatterbox: 2_300_000_000,
        .chatterboxTurbo: 2_300_000_000,
        .fishS2Pro: 11_100_000_000,
    ]

    init(root: URL, uiTest: Bool) {
        self.root = root
        self.uiTest = uiTest
        refresh()
    }

    func state(for backend: BackendID) -> State {
        uiTest ? .ready : (states[backend] ?? .notDownloaded)
    }

    func directory(for backend: BackendID) -> URL {
        root.appendingPathComponent(backend.rawValue)
    }

    func refresh() {
        for backend in [BackendID.chatterbox, .chatterboxTurbo, .fishS2Pro] {
            let config = directory(for: backend).appendingPathComponent("config.json")
            if case .downloading = states[backend] { continue }
            states[backend] = FileManager.default.fileExists(atPath: config.path)
                ? .ready : .notDownloaded
        }
    }

    func download(_ backend: BackendID) {
        if case .downloading = states[backend] { return }   // already in flight
        do { try preflight(backend) } catch {
            states[backend] = .failed(error.localizedDescription)
            return
        }
        states[backend] = .downloading(0)
        let dest = directory(for: backend)
        let repo = backend.spec.modelRepo
        downloadTasks[backend] = Task {
            do {
                guard let repoID = Repo.ID(rawValue: repo) else {
                    self.states[backend] = .failed("Invalid repo id: \(repo)")
                    self.downloadTasks[backend] = nil
                    return
                }
                let client = HubClient()
                _ = try await client.downloadSnapshot(
                    of: repoID,
                    to: dest,
                    progressHandler: { [weak self] progress in
                        self?.states[backend] = .downloading(progress.fractionCompleted)
                    })
                self.states[backend] = .ready
            } catch is CancellationError {
                self.states[backend] = .notDownloaded
            } catch {
                self.states[backend] = .failed(error.localizedDescription)
            }
            self.downloadTasks[backend] = nil
        }
    }

    func cancelDownload(_ backend: BackendID) {
        downloadTasks[backend]?.cancel()
    }

    func delete(_ backend: BackendID) {
        downloadTasks[backend]?.cancel()
        try? FileManager.default.removeItem(at: directory(for: backend))
        states[backend] = .notDownloaded
    }

    struct InsufficientDiskSpace: LocalizedError {
        let needed: Int64
        var errorDescription: String? {
            "Not enough free disk space — about "
            + ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            + " is needed."
        }
    }

    private func preflight(_ backend: BackendID) throws {
        let needed = Int64(Double(Self.approxBytes[backend] ?? 3_000_000_000) * 1.1)
        let values = try root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw InsufficientDiskSpace(needed: needed)
        }
        try FileManager.default.createDirectory(
            at: directory(for: backend), withIntermediateDirectories: true)
    }
}
