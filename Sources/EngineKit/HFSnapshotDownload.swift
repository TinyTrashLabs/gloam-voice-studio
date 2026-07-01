import Foundation

/// Thrown by `downloadHFSnapshot` on a bad repo id or an HTTP failure.
public struct HFSnapshotDownloadError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Downloads every file in a HuggingFace repo into `dest`, preserving any
/// subdirectories (e.g. Qwen3's `speech_tokenizer/`). Self-contained
/// (Foundation only) so library and CLI consumers can share one downloader.
///
/// We enumerate the repo file tree and fetch each `resolve/main/<path>` URL
/// ourselves rather than via HubClient.downloadSnapshot because
/// swift-huggingface 0.9.0 throws "Invalid file destination" for nested repo
/// files when copying to an explicit destination — flat repos work, subdir
/// repos don't. Public resolve URLs need no auth for mlx-community repos.
///
/// `progress` reports cumulative completion 0.0…1.0 (weighted by byte size when
/// the tree API returns sizes, else by file count). Files already present at the
/// expected size are skipped so re-runs are cheap.
public func downloadHFSnapshot(repo: String, to dest: URL,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
    struct Entry: Decodable { let type: String; let path: String; let size: Int64? }

    guard let treeURL = URL(
        string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
        throw HFSnapshotDownloadError("Invalid repo id: \(repo)")
    }

    let (listData, treeResponse) = try await URLSession.shared.data(from: treeURL)
    if let http = treeResponse as? HTTPURLResponse, http.statusCode != 200 {
        throw HFSnapshotDownloadError("\(repo): tree listing HTTP \(http.statusCode)")
    }
    let files = try JSONDecoder().decode([Entry].self, from: listData)
        .filter { $0.type == "file" }
    guard !files.isEmpty else {
        throw HFSnapshotDownloadError("No files found in \(repo)")
    }

    // Weight progress by bytes when sizes are present, else by file count.
    let haveSizes = files.contains { $0.size != nil }
    let total = haveSizes
        ? max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        : Int64(files.count)
    var done: Int64 = 0

    let fm = FileManager.default
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    progress(0)

    for file in files {
        try Task.checkCancellation()
        let unit: Int64 = haveSizes ? (file.size ?? 0) : 1
        let target = dest.appendingPathComponent(file.path)

        // Skip files already present with the expected size (cheap re-runs).
        if let size = file.size,
           let attrs = try? fm.attributesOfItem(atPath: target.path),
           let onDisk = attrs[.size] as? Int64, onDisk == size {
            done += unit
            progress(Double(done) / Double(total))
            continue
        }

        guard let src = URL(
            string: "https://huggingface.co/\(repo)/resolve/main/\(file.path)") else { continue }
        try fm.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmp, response) = try await URLSession.shared.download(from: src)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HFSnapshotDownloadError("\(file.path): HTTP \(http.statusCode)")
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
        done += unit
        progress(Double(done) / Double(total))
    }
}
