import Foundation
import ZIPFoundation

/// The one-file voice pack: a deflate zip holding exactly meta.json + ref.wav.
/// The format is canonical in the Python repo; both implementations conform.
public enum GVoice {
    public static func export(_ slug: String, from library: VoiceLibrary) throws -> Data {
        let (meta, refURL) = try library.get(slug)
        let ref = try Data(contentsOf: refURL)
        return try makeArchive(entries: [
            ("meta.json", try JSONEncoder().encode(meta)),
            ("ref.wav", ref),
        ])
    }

    public static func `import`(_ data: Data, into library: VoiceLibrary) throws -> VoiceMeta {
        do {
            let archive = try Archive(data: data, accessMode: .read)
            guard let metaEntry = archive["meta.json"], let refEntry = archive["ref.wav"]
            else { throw StudioError.invalidArchive("missing meta.json or ref.wav") }
            let metaData = try extract(metaEntry, from: archive)
            let ref = try extract(refEntry, from: archive)
            // VoiceMeta's tolerant init handles missing slug/createdAt/refText.
            // A missing name field causes JSONDecoder to throw, landing on the
            // canonical "no voice name" error via the guard below.
            let vm = try? JSONDecoder().decode(VoiceMeta.self, from: metaData)
            guard let name = vm?.name, !name.isEmpty else {
                throw StudioError.invalidArchive("archive meta.json has no voice name")
            }
            return try library.save(name: name, refWav: ref, refText: vm?.refText ?? "")
        } catch let error as StudioError {
            throw error
        } catch {
            throw StudioError.invalidArchive("not a valid .gvoice archive: \(error)")
        }
    }

    static func makeArchive(entries: [(name: String, data: Data)]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (name, data) in entries {
            let bytes = data
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(bytes.count),
                compressionMethod: .deflate
            ) { position, size -> Data in
                let start = Int(position)
                let end = min(start + size, bytes.count)
                return bytes.subdata(in: start..<end)
            }
        }
        guard let out = archive.data else {
            throw StudioError.invalidArchive("zip create failed")
        }
        return out
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }
}
