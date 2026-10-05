import Foundation

/// Phone-only cache of an encoded engine prompt per voice, keyed by the
/// reference file's modification date: `Caches/lux-prompts/<slug>.json`.
/// Not a pack member — a prompt is derived from the reference by ONE engine
/// build's encoder and is worthless to any other reader.
public struct PromptCache<Prompt: Codable> {
    public let directory: URL

    public static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lux-prompts", isDirectory: true)
    }

    private struct Entry: Codable {
        public let referenceModified: TimeInterval
        public let prompt: Prompt
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func prompt(for slug: String, referenceModified: Date) -> Prompt? {
        guard let data = try? Data(contentsOf: url(slug)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.referenceModified == referenceModified.timeIntervalSince1970
        else { return nil }
        return entry.prompt
    }

    public func store(_ prompt: Prompt, for slug: String, referenceModified: Date) throws {
        let entry = Entry(referenceModified: referenceModified.timeIntervalSince1970, prompt: prompt)
        try JSONEncoder().encode(entry).write(to: url(slug), options: .atomic)
    }

    public func invalidate(_ slug: String) {
        try? FileManager.default.removeItem(at: url(slug))
    }

    private func url(_ slug: String) -> URL {
        directory.appendingPathComponent("\(slug).json")
    }
}
