import Foundation
import Observation
import SpeechKit
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
        if let s = installStates[voice.id] { return s }
        let slug = (try? Slug.slugify(voice.name)) ?? voice.name.lowercased()
        if installedSlugs.contains(slug) { return .installed }
        return .available
    }

    // MARK: - Install

    func install(_ voice: CatalogVoice, into library: VoiceLibrary, transcriber: any Transcriber) {
        guard installTasks[voice.id] == nil else { return }
        installStates[voice.id] = .downloading(0)
        installTasks[voice.id] = Task {
            await performInstall(voice, into: library, transcriber: transcriber)
            installTasks[voice.id] = nil
        }
    }

    private func performInstall(_ voice: CatalogVoice, into library: VoiceLibrary, transcriber: any Transcriber) async {
        let baseSlug: String
        do {
            baseSlug = try Slug.slugify(voice.name)
        } catch {
            installStates[voice.id] = .failed("Invalid voice name: \(voice.name)")
            return
        }

        // Derive language prefix for transcription hint (e.g. "en" from "en_US")
        let langHint: String? = {
            let prefix = String(voice.language.prefix(2)).lowercased()
            return prefix.isEmpty ? nil : prefix
        }()

        for clip in voice.clips {
            // 1. Obtain WAV data
            let wavData: Data
            if let bundledName = clip.bundledResource {
                // Try with subdirectory first, then flat
                let nameWithoutExt = (bundledName as NSString).deletingPathExtension
                if let url = Bundle.main.url(forResource: nameWithoutExt, withExtension: "wav", subdirectory: "voices")
                    ?? Bundle.main.url(forResource: nameWithoutExt, withExtension: "wav") {
                    guard let data = try? Data(contentsOf: url) else {
                        installStates[voice.id] = .failed("Could not read bundled resource: \(bundledName)")
                        return
                    }
                    wavData = data
                } else {
                    installStates[voice.id] = .failed("Bundled resource not found: \(bundledName)")
                    return
                }
            } else if let audioURLStr = clip.audioURL, let audioURL = URL(string: audioURLStr) {
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(voice.id + "-\(clip.emotion ?? "base").mp3")
                do {
                    let (downloadedURL, _) = try await URLSession.shared.download(from: audioURL)
                    try? FileManager.default.removeItem(at: tempFile)
                    try FileManager.default.moveItem(at: downloadedURL, to: tempFile)
                } catch {
                    installStates[voice.id] = .failed(error.localizedDescription)
                    return
                }
                defer { try? FileManager.default.removeItem(at: tempFile) }
                guard let converted = AudioImport.wavData(fromFileAt: tempFile) else {
                    installStates[voice.id] = .failed("Audio conversion failed for clip")
                    return
                }
                wavData = converted
            } else {
                // No source — skip this clip
                continue
            }

            // 2. Determine refText (transcribe if empty)
            var refText = clip.refText
            if refText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let transcript = try await transcriber.transcribe(wavData: wavData, languageHint: langHint)
                    refText = transcript.text
                } catch {
                    // Fall back to empty string — don't fail the whole install
                    refText = ""
                }
            }

            // 3. Save to library
            do {
                if let emotion = clip.emotion {
                    let variantSlug = "\(baseSlug)-\(emotion)"
                    let variantName = "\(voice.name) (\(emotion))"
                    try library.saveAt(slug: variantSlug, name: variantName, refWav: wavData, refText: refText)
                } else {
                    // Base clip — use saveAt to allow re-install overwriting
                    try library.saveAt(slug: baseSlug, name: voice.name, refWav: wavData, refText: refText)
                }
            } catch {
                installStates[voice.id] = .failed(error.localizedDescription)
                return
            }
        }

        installStates[voice.id] = .installed
    }
}
