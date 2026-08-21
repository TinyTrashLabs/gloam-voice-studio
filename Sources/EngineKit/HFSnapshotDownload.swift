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
///
/// Progress advances as bytes arrive, not once per completed file: SuperTonic's
/// largest single asset is ~256 MB, so a per-file callback leaves the fraction
/// frozen for many minutes during a perfectly healthy download and forces
/// consumers' stall detectors to use a bound long enough to hide a dead one.
/// We therefore stream each file with `URLSession.bytes(from:)` instead of
/// `download(from:)`, which surfaces nothing until the transfer completes.
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
        let (body, response) = try await URLSession.shared.bytes(from: src)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HFSnapshotDownloadError("\(file.path): HTTP \(http.statusCode)")
        }

        // Stream to a sibling ".partial" file, then rename into place. Sibling
        // (not the system temp dir) so the move is a same-volume rename rather
        // than a copy — a half-written file must never appear at `target`, or the
        // already-present-at-expected-size skip above would treat a truncation as
        // done on the next run. Any throw — HTTP error, cancellation, disk full —
        // deletes the partial before propagating, matching what
        // `URLSession.download` used to give us for free.
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial")
        try? fm.removeItem(at: partial)

        let expected: Int64 = haveSizes ? (file.size ?? 0) : 0
        var written: Int64 = 0
        var reportedAt: Int64 = 0
        var lastReport = ContinuousClock.now
        do {
            try await streamToFile(body, at: partial) { chunk in
                // Cancellation is honoured at chunk boundaries as well as by the
                // byte stream itself, so an injected sequence behaves like a
                // real transfer.
                try Task.checkCancellation()
                written += chunk
                // Intra-file progress needs a denominator; with no tree sizes the
                // fraction is file-counted and only moves when a file completes.
                guard expected > 0 else { return }
                let now = ContinuousClock.now
                guard written - reportedAt >= hfProgressReportBytes
                    || now - lastReport >= hfProgressReportInterval else { return }
                reportedAt = written
                lastReport = now
                // Clamp: a server that sends more than the tree advertised must
                // not push the fraction past this file's share.
                progress(min(1, Double(done + min(written, expected)) / Double(total)))
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        try? fm.removeItem(at: target)
        try fm.moveItem(at: partial, to: target)
        done += unit
        progress(Double(done) / Double(total))
    }
}

/// Coalescing granularity for in-flight progress: report after 1 MiB of new
/// bytes, or after 250 ms if fewer than that have arrived. The byte bound keeps
/// a fast transfer from firing thousands of callbacks (256 MB ⇒ ~256 reports,
/// not ~268M), and the time bound keeps a slow link visibly moving — at 100 kB/s
/// the fraction ticks a couple of times a second instead of once per megabyte,
/// so a consumer's stall detector can use a bound measured in seconds instead of
/// minutes. The real floor is the disk-flush size below: progress can only be
/// evaluated at a flush boundary, so reports are at most one per 64 KiB.
let hfProgressReportBytes: Int64 = 1 << 20
let hfProgressReportInterval: Duration = .milliseconds(250)

/// Streams `bytes` into a new file at `url`, flushing to disk every
/// `bufferBytes` so a ~256 MB asset is never held in memory, and handing each
/// flushed chunk's size to `onChunk`. 64 KiB keeps the write count sane while
/// still giving a slow connection a progress tick every second or two. Split out
/// of `downloadHFSnapshot` so the streaming and progress-coalescing behaviour can
/// be exercised against an injected sequence, with no network fetch.
func streamToFile<S: AsyncSequence>(
    _ bytes: S,
    at url: URL,
    bufferBytes: Int = 64 * 1024,
    onChunk: (Int64) throws -> Void
) async throws where S.Element == UInt8 {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw HFSnapshotDownloadError("Could not create \(url.path)")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }

    var buffer = Data()
    buffer.reserveCapacity(bufferBytes)
    for try await byte in bytes {
        buffer.append(byte)
        guard buffer.count >= bufferBytes else { continue }
        try handle.write(contentsOf: buffer)
        let flushed = Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        try onChunk(flushed)
    }
    if !buffer.isEmpty {
        try handle.write(contentsOf: buffer)
        try onChunk(Int64(buffer.count))
    }
}
