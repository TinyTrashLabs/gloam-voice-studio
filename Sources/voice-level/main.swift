import Foundation
import StudioKit
import ZIPFoundation

/// Bring existing references up to the loudness standard.
///
/// `VoiceLibrary` applies the standard at its write sites, so every voice saved
/// from now on meets it. That does nothing for the voices already on disk, and
/// nothing for the `.gvoice` packs bundled into the app — this walks those and
/// rewrites them in place.
///
///     swift run voice-level --dry-run ~/Library/…/Voices packs/*.gvoice
///     swift run voice-level --transcode ~/Library/…/Voices
///
/// `--dry-run` measures and reports without writing. `--transcode` additionally
/// repairs references that are not WAV at all (MP3/M4A saved under a `.wav`
/// name) by decoding them to real PCM — without it those are reported and
/// skipped, because rewriting a reference's container is a bigger edit than
/// levelling and should be asked for explicitly.

// MARK: - Arguments

var paths: [String] = []
var dryRun = false
var transcode = false
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--dry-run": dryRun = true
    case "--transcode": transcode = true
    case let other where other.hasPrefix("--"):
        FileHandle.standardError.write(Data("unknown flag: \(other)\n".utf8))
        exit(2)
    case let other: paths.append(other)
    }
}
guard !paths.isEmpty else {
    print("usage: voice-level [--dry-run] [--transcode] <voices-dir | voice-dir | pack.gvoice>...")
    exit(2)
}

// MARK: - Measurement

/// Loudness of a WAV, or nil when the bytes are not a form we can measure.
@MainActor
func measure(_ wav: Data) -> Float? {
    guard let chunk = RefLoudness.dataChunk(in: wav) else { return nil }
    let step = chunk.format == .pcm16 ? 2 : 4
    let count = chunk.length / step
    guard count > 0 else { return nil }
    var samples = [Float](repeating: 0, count: count)
    wav.withUnsafeBytes { raw in
        let base = raw.baseAddress!.advanced(by: chunk.offset)
        for i in 0 ..< count {
            if chunk.format == .pcm16 {
                let lo = UInt16(base.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                samples[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            } else {
                var bits: UInt32 = 0
                for b in 0 ..< 4 {
                    bits |= UInt32(base.load(fromByteOffset: i * 4 + b, as: UInt8.self)) << (8 * UInt32(b))
                }
                samples[i] = Float(bitPattern: bits)
            }
        }
    }
    let value = Loudness.lufs(samples, sampleRate: chunk.sampleRate)
    return value.isFinite ? value : nil
}

var levelled = 0, alreadyFine = 0, transcoded = 0, unreadable = 0

/// Level one reference's bytes. Returns the new bytes, or nil to leave alone.
@MainActor
func process(_ wav: Data, label: String) -> Data? {
    guard let before = measure(wav) else {
        // Not WAV at all. The loudness standard cannot see inside it, and until
        // it is a real WAV nothing downstream can level it either.
        guard transcode, let samples = try? RefAudioCombiner.decodeMono(wav) else {
            print("  \(label): NOT A WAV — \(transcode ? "could not decode" : "skipped, pass --transcode")")
            unreadable += 1
            return nil
        }
        let rebuilt = WAVEncoder.encode(pcm16: PCM16.data(from: samples),
                                        sampleRate: Int(RefAudioCombiner.targetSampleRate))
        let out = RefLoudness.normalized(wav: rebuilt)
        let after = measure(out).map { String(format: "%.1f", $0) } ?? "?"
        print("  \(label): transcoded to WAV → \(after) LUFS")
        transcoded += 1
        return out
    }
    let out = RefLoudness.normalized(wav: wav)
    guard let after = measure(out) else { return nil }
    if out == wav {
        print(String(format: "  %@: %.1f LUFS — already at standard", label, before))
        alreadyFine += 1
        return nil
    }
    print(String(format: "  %@: %.1f → %.1f LUFS (%+.1f)", label, before, after, after - before))
    levelled += 1
    return out
}

// MARK: - Voice directories

let fm = FileManager.default

/// Every reference inside a voice directory: the source `ref.wav` and each
/// engine's derived one. The engine copy matters as much as the source — it is
/// the file LuxTTS actually renders a cloned voice from, and levelling only the
/// source leaves the audible asset untouched.
@MainActor
func references(inVoiceDir dir: URL) -> [URL] {
    var out: [URL] = []
    let root = dir.appendingPathComponent("ref.wav")
    if fm.fileExists(atPath: root.path) { out.append(root) }
    let engines = dir.appendingPathComponent("engines")
    if let kids = try? fm.contentsOfDirectory(at: engines, includingPropertiesForKeys: nil) {
        for engine in kids {
            let ref = engine.appendingPathComponent("ref.wav")
            if fm.fileExists(atPath: ref.path) { out.append(ref) }
        }
    }
    return out
}

@MainActor
func handleVoiceDir(_ dir: URL) {
    let refs = references(inVoiceDir: dir)
    guard !refs.isEmpty else { return }
    print(dir.lastPathComponent)
    for ref in refs {
        guard let wav = try? Data(contentsOf: ref) else { continue }
        let label = ref.path.hasSuffix("/ref.wav") && ref.deletingLastPathComponent() == dir
            ? "ref.wav"
            : "engines/\(ref.deletingLastPathComponent().lastPathComponent)/ref.wav"
        guard let out = process(wav, label: label) else { continue }
        if !dryRun { try? out.write(to: ref) }
    }
}

// MARK: - Packs

/// A `.gvoice` is a zip, so it is rewritten rather than edited: entries are
/// copied into a fresh archive with the reference entries replaced. Rewriting
/// preserves every other entry (manifest, baked engine assets) byte for byte.
@MainActor
func handlePack(_ pack: URL) {
    print(pack.lastPathComponent)
    guard let archive = try? Archive(url: pack, accessMode: .read) else {
        print("  not a readable archive"); unreadable += 1; return
    }
    var replacements: [String: Data] = [:]
    var entries: [(String, Data)] = []
    for entry in archive {
        var bytes = Data()
        guard (try? archive.extract(entry, consumer: { bytes.append($0) })) != nil else { continue }
        entries.append((entry.path, bytes))
        // Every ref.wav in the pack, wherever it sits: source/ and engines/*/.
        if entry.path.hasSuffix("ref.wav"), let out = process(bytes, label: entry.path) {
            replacements[entry.path] = out
        }
    }
    guard !replacements.isEmpty, !dryRun else { return }
    let temp = pack.deletingLastPathComponent()
        .appendingPathComponent("\(pack.lastPathComponent).rewrite")
    try? fm.removeItem(at: temp)
    guard let out = try? Archive(url: temp, accessMode: .create) else {
        print("  could not open a rewrite target"); return
    }
    for (path, bytes) in entries {
        let data = replacements[path] ?? bytes
        try? out.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                          provider: { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        })
    }
    // Only swap once the rewrite is complete, so an interrupted run cannot leave
    // a bundled host half-written.
    try? fm.removeItem(at: pack)
    try? fm.moveItem(at: temp, to: pack)
}

// MARK: - Walk

for path in paths {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension == "gvoice" { handlePack(url); continue }
    // A voice directory holds ref.wav directly; anything else holding voice
    // directories is treated as a library root.
    if !references(inVoiceDir: url).isEmpty {
        handleVoiceDir(url)
    } else if let kids = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
        for kid in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: kid.path, isDirectory: &isDir), isDir.boolValue else { continue }
            handleVoiceDir(kid)
        }
    } else {
        print("\(path): not a voice, library or pack")
    }
}

print("""

\(dryRun ? "DRY RUN — nothing written" : "written")
  levelled:    \(levelled)
  already ok:  \(alreadyFine)
  transcoded:  \(transcoded)
  unreadable:  \(unreadable)
""")
