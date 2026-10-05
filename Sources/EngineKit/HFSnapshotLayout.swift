import Foundation

/// The pure, network-free half of a Hugging Face snapshot download: which tree entries are files to fetch,
/// where each one lands on disk, and what a successful download may delete afterwards. Shared by the app's
/// downloader (`ModelDownloadManager`) and `downloadHFSnapshot`, and tested without touching the network.
public enum HFSnapshotLayout {
    /// One entry of `GET /api/models/<repo>/tree/main?recursive=true`.
    public struct Entry: Decodable, Sendable, Equatable {
        public let type: String
        public let path: String
        public let size: Int64?
        public init(type: String, path: String, size: Int64?) {
            self.type = type; self.path = path; self.size = size
        }
    }

    /// Top-level folders in a model directory that belong to the user, never to the repo, and that no prune
    /// touches. `voices/` holds hand-prepared voices beside the Neural Engine model set.
    public static let userFolders: Set<String> = ["voices"]

    /// The files in a recursive tree listing. A recursive listing names every file by its full path
    /// (`coreml/talker0.mlmodelc/weights/weight.bin`), so a `.mlmodelc` — a DIRECTORY of files — arrives as
    /// its files; directory entries carry nothing to fetch and are dropped. A path that could escape the
    /// destination (absolute, `..`, empty components) is dropped too.
    public static func files(inTree data: Data) throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && isSafeRelativePath($0.path) }
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Where `path` downloads from.
    public static func resolveURL(repo: String, path: String) -> URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")
    }

    /// Where `path` lands under `dir`, nested folders included (the caller creates the parent).
    public static func target(for path: String, in dir: URL) -> URL {
        dir.appendingPathComponent(path, isDirectory: false)
    }

    /// Deletes what a just-completed download of a repo containing `repoPaths` left behind in `dir`: files the
    /// repo does not contain, then any folder the prune emptied.
    ///
    /// Never touches `keepNames` (file names, anywhere) or anything under `userFolders`. With
    /// `onlyRepoFolders`, it also never touches a file outside a top-level folder the repo itself has — for a
    /// directory a user may keep their own things in (the Neural Engine set's folder, which the engine is
    /// also pointed at by hand), only the repo's own folders are the downloader's to clean.
    ///
    /// ONLY call this after a successful download: pruning after a failed or cancelled one would wipe the
    /// working model a user already had.
    public static func prune(keeping repoPaths: Set<String>, under dir: URL,
                             keepNames: Set<String> = [], onlyRepoFolders: Bool = false) {
        let fm = FileManager.default
        let repoFolders = Set(repoPaths.compactMap { p -> String? in
            let parts = p.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : nil
        })
        // `enumerator(atPath:)` yields paths RELATIVE to `dir`, which is what `repoPaths` holds. Deriving them
        // from absolute URLs instead looks equivalent and is not: on macOS the enumerator hands back
        // `/private/var/...` for a `/var/...` root, the prefix match fails, and every file in a subdirectory
        // stops matching its repo path and gets deleted.
        guard let walk = fm.enumerator(atPath: dir.path) else { return }
        var dirs: [String] = []
        for case let relative as String in walk {
            let top = String(relative.split(separator: "/").first ?? "")
            if userFolders.contains(top) {
                walk.skipDescendants()
                continue
            }
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(relative)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if onlyRepoFolders && !repoFolders.contains(top) { walk.skipDescendants(); continue }
                dirs.append(relative)
                continue
            }
            if onlyRepoFolders && !repoFolders.contains(top) { continue }
            guard !repoPaths.contains(relative), !keepNames.contains(url.lastPathComponent) else { continue }
            try? fm.removeItem(at: url)
        }
        // Deepest first, so a folder emptied by removing its children goes on the same pass.
        for relative in dirs.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let url = dir.appendingPathComponent(relative)
            if let left = try? fm.contentsOfDirectory(atPath: url.path), left.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
    }
}
