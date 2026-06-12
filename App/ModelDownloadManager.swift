import EngineKit
import Foundation
import Observation

@MainActor @Observable
final class ModelDownloadManager {
    enum State: Equatable {
        case notDownloaded, downloading(Double), ready, failed(String)
    }
    let root: URL
    let uiTest: Bool
    private(set) var states: [BackendID: State] = [:]

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
}
