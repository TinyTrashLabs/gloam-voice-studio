import Foundation
import GVoiceProductionKit

func runGVoicePrepare(_ arguments: [String]) async throws {
    let options = try GVoicePrepareOptions.parse(arguments)
    let transcript = try String(contentsOf: options.transcriptFile, encoding: .utf8)
    let separator: (any VoiceStemSeparating)?
    if options.recipe.mode == .isolateVocals {
        guard let weights = options.weights else {
            throw ReferencePreparationError.separationUnavailable("--weights is required for isolate-vocals")
        }
        separator = try await SwiftDemucsSeparator(weightsDirectory: weights)
    } else {
        separator = nil
    }
    let result = try await ReferencePreparer(separator: separator).prepare(.init(
        sourceURL: options.input, sourceIdentity: options.sourceIdentity,
        transcript: transcript, recipe: options.recipe))
    try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
    try result.wav.write(to: options.output.appendingPathComponent("ref.wav"), options: .atomic)
    try Data(result.transcript.utf8).write(to: options.output.appendingPathComponent("ref.txt"), options: .atomic)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = ReferenceCleanupReport(recipe: options.recipe, metrics: result.metrics,
                                        verification: result.verification)
    try encoder.encode(report).write(to: options.output.appendingPathComponent("cleanup-report.json"), options: .atomic)
    try encoder.encode(result.provenance).write(to: options.output.appendingPathComponent("provenance.json"), options: .atomic)
    print("wrote \(options.output.path)")
}
