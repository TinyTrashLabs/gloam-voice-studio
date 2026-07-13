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
    private(set) var llmStates: [LLMBackendID: State] = [:]
    private var llmDownloadTasks: [LLMBackendID: Task<Void, Never>] = [:]

    /// Approximate 8-bit download sizes; scaled by the selected quant.
    static let approxBytes8bit: [BackendID: Int64] = [
        .qwen06B: 1_200_000_000,
        .qwen17B: 1_900_000_000,
        .qwenDesign: 1_900_000_000,
        .qwenCustom: 1_900_000_000,
        .chatterbox: 2_300_000_000,
        .chatterboxTurbo: 2_300_000_000,
        .fishS2Pro: 11_100_000_000,
        // The HF repo is 389MB total; only the 54 small per-voice .pt (PyTorch)
        // duplicates (~28MB combined) are redundant — the 327MB main-model
        // safetensors file has no .pt counterpart. downloadRepoSnapshot below
        // skips .pt, so ~361MB is the real download (confirmed via a live
        // `spike` CLI run: 361,127,491 bytes).
        .kokoro: 365_000_000,
    ]

    func approxBytes(for backend: BackendID) -> Int64 {
        let base = Self.approxBytes8bit[backend] ?? 3_000_000_000
        guard backend.isQwen else { return base }
        return Int64(Double(base) * quant(for: backend).sizeMultiplier)
    }

    init(root: URL, uiTest: Bool) {
        self.root = root
        self.uiTest = uiTest
        Self.migrateLegacyQwenDir(root: root)
        refresh()
    }

    /// The first model currently downloading (TTS first, then LLM), with its
    /// progress fraction — drives the global download indicator in the toolbar.
    var activeDownload: (label: String, fraction: Double)? {
        for backend in BackendID.allCases {
            if case .downloading(let fraction) = states[backend] {
                return (backend.rawValue, fraction)
            }
        }
        for backend in LLMBackendID.allCases {
            if case .downloading(let fraction) = llmStates[backend] {
                return (backend.rawValue, fraction)
            }
        }
        return nil
    }

    func state(for backend: BackendID) -> State {
        uiTest ? .ready : (states[backend] ?? .notDownloaded)
    }

    /// Per-Qwen selected precision (persisted). Non-Qwen ignore this.
    func quant(for backend: BackendID) -> QwenQuant {
        guard backend.isQwen else { return .q8 }
        let raw = UserDefaults.standard.string(forKey: "qwenQuant.\(backend.rawValue)")
        return raw.flatMap(QwenQuant.init(rawValue:)) ?? .q8
    }

    func setQuant(_ quant: QwenQuant, for backend: BackendID) {
        guard backend.isQwen else { return }
        UserDefaults.standard.set(quant.rawValue, forKey: "qwenQuant.\(backend.rawValue)")
        refresh()   // selected dir may differ → recompute state
    }

    func directory(for backend: BackendID) -> URL {
        root.appendingPathComponent(backend.diskFolder(quantRaw: quant(for: backend).rawValue))
    }

    /// The retired `.qwen3` backend (0.6B-Base-8bit) downloaded to `Models/qwen3`.
    /// Move it to the new quant-suffixed location so it isn't re-downloaded.
    private static func migrateLegacyQwenDir(root: URL) {
        let old = root.appendingPathComponent("qwen3")
        let new = root.appendingPathComponent(BackendID.qwen06B.diskFolder(quantRaw: "8bit"))
        let fm = FileManager.default
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
    }

    func refresh() {
        for backend in BackendID.allCases {
            if case .downloading = states[backend] { continue }
            states[backend] = isComplete(backend) ? .ready : .notDownloaded
        }
        for backend in LLMBackendID.allCases {
            if case .downloading = llmStates[backend] { continue }
            llmStates[backend] = isComplete(dir: llmDirectory(for: backend))
                ? .ready : .notDownloaded
        }
    }

    /// A model is only "ready" if it has both a config AND the actual weight
    /// file(s). An interrupted download can leave the small non-LFS files
    /// (config.json, tokenizer.json) behind without `model.safetensors` — that
    /// dir would otherwise read as ready and then fail at generate time with a
    /// confusing `modelNotInitialized`. Require weights so the UI honestly
    /// offers a (re)download instead.
    private func isComplete(dir: URL) -> Bool {
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension == "safetensors" }
    }
    private func isComplete(_ backend: BackendID) -> Bool {
        isComplete(dir: directory(for: backend))
    }

    func download(_ backend: BackendID) {
        if case .downloading = states[backend] { return }   // already in flight
        do { try preflight(backend) } catch {
            states[backend] = .failed(error.localizedDescription)
            return
        }
        states[backend] = .downloading(0)
        let dest = directory(for: backend)
        let repo = backend.modelRepo(quant: quant(for: backend))
        downloadTasks[backend] = Task {
            do {
                try await downloadRepoSnapshot(repo: repo, to: dest) { fraction in
                    self.states[backend] = .downloading(fraction)
                }
                self.states[backend] = .ready
            } catch is CancellationError {
                self.states[backend] = .notDownloaded
            } catch {
                self.states[backend] = .failed(error.localizedDescription)
            }
            self.downloadTasks[backend] = nil
        }
    }

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads every file in a HuggingFace repo to `dir`, preserving any
    /// subdirectories (e.g. Qwen3's `speech_tokenizer/`). We do this ourselves
    /// rather than via HubClient.downloadSnapshot because swift-huggingface 0.9.0
    /// throws "Invalid file destination" for nested repo files when copying to an
    /// explicit destination — flat repos (chatterbox/fish) work, subdir repos
    /// (qwen3) don't. Public resolve URLs need no auth for mlx-community repos.
    private func downloadRepoSnapshot(repo: String, to dir: URL,
                                      onProgress: (Double) -> Void) async throws {
        struct Entry: Decodable { let type: String; let path: String; let size: Int64? }
        guard let treeURL = URL(
            string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            throw DownloadError(message: "Invalid repo id: \(repo)")
        }
        let (listData, _) = try await URLSession.shared.data(from: treeURL)
        let files = try JSONDecoder().decode([Entry].self, from: listData)
            // MLX only ever reads .safetensors — Kokoro's repo carries 54 redundant
            // .pt (PyTorch) copies of the same voicepacks that would otherwise
            // roughly double its download for nothing.
            .filter { $0.type == "file" && !$0.path.hasSuffix(".pt") }
        guard !files.isEmpty else {
            throw DownloadError(message: "No files found in \(repo)")
        }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Task.checkCancellation()
            guard let src = URL(
                string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)") else { continue }
            let target = dir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: src)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw DownloadError(message: "\(file.path): HTTP \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            done += file.size ?? 0
            onProgress(Double(done) / Double(total))
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

    private func preflight(needed approxBytes: Int64, dir: URL) throws {
        let needed = Int64(Double(approxBytes) * 1.1)
        let values = try root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw InsufficientDiskSpace(needed: needed)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    private func preflight(_ backend: BackendID) throws {
        try preflight(needed: approxBytes(for: backend), dir: directory(for: backend))
    }

    // MARK: LLM downloads — parallel to the TTS surface, keyed by LLMBackendID.
    // Weights land in root/llm-<rawValue>, exactly where MLXLanguageModelProvider
    // (wired in AppModel) resolves them.

    func llmDirectory(for backend: LLMBackendID) -> URL {
        root.appendingPathComponent(backend.diskFolder)
    }

    func state(for backend: LLMBackendID) -> State {
        uiTest ? .ready : (llmStates[backend] ?? .notDownloaded)
    }

    func download(_ backend: LLMBackendID) {
        if case .downloading = llmStates[backend] { return }
        let dest = llmDirectory(for: backend)
        do { try preflight(needed: backend.approxBytes, dir: dest) } catch {
            llmStates[backend] = .failed(error.localizedDescription)
            return
        }
        llmStates[backend] = .downloading(0)
        llmDownloadTasks[backend] = Task {
            do {
                try await downloadRepoSnapshot(repo: backend.repoId, to: dest) { fraction in
                    self.llmStates[backend] = .downloading(fraction)
                }
                self.llmStates[backend] = .ready
            } catch is CancellationError {
                self.llmStates[backend] = .notDownloaded
            } catch {
                self.llmStates[backend] = .failed(error.localizedDescription)
            }
            self.llmDownloadTasks[backend] = nil
        }
    }

    func cancelDownload(_ backend: LLMBackendID) {
        llmDownloadTasks[backend]?.cancel()
    }

    func delete(_ backend: LLMBackendID) {
        llmDownloadTasks[backend]?.cancel()
        try? FileManager.default.removeItem(at: llmDirectory(for: backend))
        llmStates[backend] = .notDownloaded
    }
}
