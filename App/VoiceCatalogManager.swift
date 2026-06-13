import Foundation
import Observation
import StudioKit

@MainActor @Observable
final class VoiceCatalogManager {
    enum InstallState: Equatable {
        case available
        case downloading(Double)
        case installed
        case failed(String)
    }

    // Set to a raw GitHub URL to enable a remote catalog override in the future.
    // When non-nil the app will attempt to fetch it and fall back to the bundled
    // catalog.json on any network error.
    static let remoteCatalogURL: URL? = nil  // TODO: point at a GitHub raw URL

    private(set) var voices: [CatalogVoice] = []
    private var installStates: [String: InstallState] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]

    init() {
        loadCatalog()
    }

    // MARK: - Catalog loading

    private func loadCatalog() {
        // Attempt remote override first (stubbed — remoteCatalogURL is nil).
        // When wired up, fetch asynchronously and call applyDecoded(_:) on success.
        if Self.remoteCatalogURL != nil {
            // Future: Task { await fetchRemote() }
        }
        loadBundled()
    }

    private func loadBundled() {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([CatalogVoice].self, from: data)
        else { return }
        voices = decoded
    }

    // MARK: - State

    func state(for voice: CatalogVoice, installedSlugs: Set<String>) -> InstallState {
        // If an in-flight or failed state exists, return it.
        if let s = installStates[voice.id] { return s }
        // Check whether a library voice with the same slug already exists.
        let slug = (try? Slug.slugify(voice.name)) ?? voice.name.lowercased()
        if installedSlugs.contains(slug) { return .installed }
        return .available
    }

    // MARK: - Install

    func install(_ voice: CatalogVoice, into library: VoiceLibrary) {
        guard installTasks[voice.id] == nil else { return }
        installStates[voice.id] = .downloading(0)
        installTasks[voice.id] = Task {
            await performInstall(voice, into: library)
            installTasks[voice.id] = nil
        }
    }

    private func performInstall(_ voice: CatalogVoice, into library: VoiceLibrary) async {
        guard let audioURL = URL(string: voice.audioURL) else {
            installStates[voice.id] = .failed("Invalid URL")
            return
        }
        // Download to a temporary file.
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(voice.id + ".mp3")
        do {
            let (downloadedURL, _) = try await URLSession.shared.download(from: audioURL)
            try? FileManager.default.removeItem(at: tempFile)
            try FileManager.default.moveItem(at: downloadedURL, to: tempFile)
        } catch {
            installStates[voice.id] = .failed(error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Convert to WAV.
        guard let wavData = AudioImport.wavData(fromFileAt: tempFile) else {
            installStates[voice.id] = .failed("Audio conversion failed")
            return
        }

        // Save into the voice library.
        do {
            _ = try library.save(name: voice.name, refWav: wavData, refText: voice.refText)
            installStates[voice.id] = .installed
        } catch StudioError.voiceExists {
            // Already installed — treat as success.
            installStates[voice.id] = .installed
        } catch {
            installStates[voice.id] = .failed(error.localizedDescription)
        }
    }
}
