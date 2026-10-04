import EngineKit
import Foundation
import StudioKit

/// `spike gvoice-qwen-sections <in.gvoice> <out.gvoice>`
///
/// Imports the pack into a scratch library, prepares the Qwen section of the base voice and of every
/// language reference / take (`VoiceLibrary.prepareQwenSections`, the same code Studio's export runs),
/// and exports it again. The result carries `engines/qwen3-0.6b/` for each variant.
func runGVoiceQwenSections(_ arguments: [String]) async throws {
    guard arguments.count == 2 else { throw QwenPrepCLIError("usage: spike gvoice-qwen-sections <in.gvoice> <out.gvoice>") }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gvoice-qwen-sections-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let lib = VoiceLibrary(directory: scratch)
    let meta = try GVoice.import(try Data(contentsOf: URL(fileURLWithPath: arguments[0])), into: lib)
    let done = await lib.prepareQwenSections(meta.slug)
    print("prepared now: \(done)")
    let pack = try GVoice.export(meta.slug, from: lib)
    try pack.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
    print("wrote \(arguments[1]) (\(pack.count) bytes)")
}
