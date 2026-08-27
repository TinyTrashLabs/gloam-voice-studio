// EspeakProcessPhonemizer.swift
// spike — dev-only out-of-process espeak-ng phonemizer
//
// Moved out of EngineKit (LuxTokenizer.swift) so `Process`-spawning code that
// shells out to a Homebrew `espeak-ng` binary never compiles into the shipping
// app or library — Mac App Store static analysis flags exactly this pattern,
// and espeak-ng is GPL-3.0 and undistributable via the App Store anyway (see
// EngineKit/LuxTTS/MisakiPhonemizer.swift's header). The `PhonemizerProviding`
// protocol this conforms to stays `public` in EngineKit; only this
// Process-spawning implementation lives here, reachable only from the
// dev-only `spike` CLI (`spike lux-phonemes`).

import EngineKit
import Foundation

/// Runs an `espeak-ng` executable per clause (`espeak-ng -q --ipa -v en-us`).
/// Default lookup order: an explicit URL passed in, then Homebrew paths.
/// For a bundled binary, pass `dataDirectory` pointing at espeak-ng-data and
/// it is exported as ESPEAK_DATA_PATH.
///
/// This is the dev-machine / direct-distribution implementation. See
/// LuxTokenizer.swift's header for the vendored-library plan
/// (`EspeakLibraryPhonemizer`).
struct EspeakProcessPhonemizer: PhonemizerProviding {
    let executableURL: URL
    let voice: String
    let dataDirectory: URL?

    static let defaultSearchPaths = [
        "/opt/homebrew/bin/espeak-ng",
        "/opt/homebrew/bin/espeak",
        "/usr/local/bin/espeak-ng",
        "/usr/local/bin/espeak",
    ]

    init(executableURL: URL, voice: String = "en-us", dataDirectory: URL? = nil) {
        self.executableURL = executableURL
        self.voice = voice
        self.dataDirectory = dataDirectory
    }

    /// Finds espeak-ng on well-known paths; throws if none exists.
    init(voice: String = "en-us") throws {
        guard let path = Self.defaultSearchPaths.first(
            where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw LuxTokenizerError.phonemizerUnavailable(
                "espeak-ng executable not found (looked in \(Self.defaultSearchPaths)). "
                + "Install with `brew install espeak-ng` or bundle a binary and use "
                + "init(executableURL:voice:dataDirectory:).")
        }
        self.init(executableURL: URL(fileURLWithPath: path), voice: voice)
    }

    func phonemize(_ normalizedEnglishText: String) throws -> [String] {
        try PiperClauseAssembler.assemble(normalizedEnglishText) { clause in
            try runEspeak(clause)
        }
    }

    private func runEspeak(_ clause: String) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-q", "--ipa", "-v", voice, "--", clause]
        if let dataDirectory {
            var env = ProcessInfo.processInfo.environment
            env["ESPEAK_DATA_PATH"] = dataDirectory.path
            process.environment = env
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw LuxTokenizerError.phonemizerUnavailable(
                "failed to launch \(executableURL.path): \(error)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else {
            throw LuxTokenizerError.phonemizationFailed(
                "espeak-ng exited with status \(process.terminationStatus) for clause: \(clause)")
        }
        // espeak prints one line per internal clause; join with a single space
        // (piper inserts a space token between clause chunks inside a sentence).
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
