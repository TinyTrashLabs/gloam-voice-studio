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
/// The byte counts come from `URLSessionDownloadDelegate`'s `didWriteData`
/// (see `downloadHFFile`), which is the loading system's own transfer, not a
/// hand-rolled copy.
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

        // Intra-file progress needs a denominator; with no tree sizes the
        // fraction is file-counted and only moves when a file completes.
        let expected: Int64 = haveSizes ? (file.size ?? 0) : 0
        var coalescer = HFProgressCoalescer()
        try await downloadHFFile(from: src, to: target, label: file.path) { written in
            // Cancellation is honoured between byte reports as well as by the
            // download task itself (`downloadHFFile` cancels the task).
            try Task.checkCancellation()
            guard expected > 0, coalescer.shouldReport(written) else { return }
            // Clamp: a server that sends more than the tree advertised must
            // not push the fraction past this file's share.
            progress(min(1, Double(done + min(written, expected)) / Double(total)))
        }

        done += unit
        progress(Double(done) / Double(total))
    }
}

/// Coalescing granularity for in-flight progress: report after 1 MiB of new
/// bytes, or after 250 ms if fewer than that have arrived. The byte bound keeps
/// a fast transfer from firing a callback per network read (256 MB ⇒ ~256
/// reports), and the time bound keeps a slow link visibly moving — at 100 kB/s
/// the fraction ticks a few times a second instead of once per megabyte, so a
/// consumer's stall detector can use a bound measured in seconds instead of
/// minutes. The real floor is the loading system's own `didWriteData` cadence:
/// we can only evaluate at a callback boundary, never more often than one
/// arrives.
let hfProgressReportBytes: Int64 = 1 << 20
let hfProgressReportInterval: Duration = .milliseconds(250)

/// Rate-limits in-flight progress reports to the granularity documented above.
/// Split out of `downloadHFSnapshot` so the granularity can be exercised
/// directly, with no network fetch and no wall-clock waiting.
struct HFProgressCoalescer {
    private var reportedAt: Int64 = 0
    private var lastReport: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now) { lastReport = now }

    /// `written` is the cumulative byte count for the file in flight.
    mutating func shouldReport(_ written: Int64,
                               now: ContinuousClock.Instant = .now) -> Bool {
        guard written - reportedAt >= hfProgressReportBytes
            || now - lastReport >= hfProgressReportInterval else { return false }
        reportedAt = written
        lastReport = now
        return true
    }
}

/// Downloads one URL to `target`, handing each cumulative byte count the URL
/// loading system reports to `onBytesWritten`. Throws
/// `HFSnapshotDownloadError` on a non-200 response and `CancellationError` if
/// the surrounding task is cancelled.
///
/// This uses `URLSessionDownloadDelegate` rather than `URLSession.bytes(from:)`.
/// `bytes(from:)` yields an `AsyncSequence<UInt8>` — one byte per async
/// iteration, so a 256 MB asset costs ~268M suspension points. Measured against
/// a local server on an M-series Mac (release build), that path burns 0.020 CPU
/// seconds per MiB and tops out at ~50 MiB/s, versus 0.0006 CPU s/MiB and
/// >2 GiB/s for both `download(from:)` and this delegate — 33x the CPU for the
/// same bytes, which on this codebase's history of background CPU-watchdog kills
/// trades a stalled download for a killed process. `didWriteData` is the
/// purpose-built API: the loading system performs the transfer at full speed off
/// our threads and just hands back counters, and `didFinishDownloadingTo` gives
/// us the completed file, exactly as `download(from:)` did.
///
/// Atomicity: nothing is written to `target` until the transfer has finished.
/// `didFinishDownloadingTo` only fires on a complete body, so a truncated file
/// can never appear at `target` — which matters because the caller's
/// "already present at the expected size" skip would treat a truncation as
/// done forever after.
func downloadHFFile(from src: URL, to target: URL, label: String,
                    onBytesWritten: (Int64) throws -> Void) async throws {
    // .bufferingNewest(1) is the first stage of coalescing: only the latest
    // cumulative count is ever interesting, so a burst of callbacks that
    // outruns the consumer collapses instead of queueing.
    let (stream, continuation) = AsyncThrowingStream<Int64, Error>.makeStream(
        bufferingPolicy: .bufferingNewest(1))

    let delegate = HFDownloadDelegate(target: target, label: label, continuation: continuation)
    // Our own session, because URLSession.shared cannot carry a delegate. The
    // delegate queue is serial so the delegate's state needs no other locking.
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
    // A session retains its delegate until invalidated, so this is what stops
    // one session-plus-delegate leaking per file.
    defer { session.invalidateAndCancel() }

    let task = session.downloadTask(with: src)
    // Covers every early exit from the loop below — a throw out of
    // `onBytesWritten`, or the task being cancelled — by cancelling the
    // transfer itself rather than just abandoning the await.
    continuation.onTermination = { _ in task.cancel() }
    task.resume()

    try await withTaskCancellationHandler {
        for try await written in stream {
            try onBytesWritten(written)
        }
        // An AsyncThrowingStream reacts to task cancellation by *ending* the
        // sequence, not by throwing, so a cancelled transfer would otherwise
        // look like a clean finish. The delegate is the only thing that can
        // finish it successfully, and it only does so after the file is in
        // place; anything else here is a cancellation.
        try Task.checkCancellation()
    } onCancel: {
        task.cancel()
    }
}

/// Bridges `URLSessionDownloadDelegate` to the `AsyncThrowingStream` above.
/// Every stored property is touched only on the session's serial delegate
/// queue, hence the unchecked conformance.
private final class HFDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let target: URL
    private let label: String
    private let continuation: AsyncThrowingStream<Int64, Error>.Continuation
    private var failure: Error?

    init(target: URL, label: String,
         continuation: AsyncThrowingStream<Int64, Error>.Continuation) {
        self.target = target
        self.label = label
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        continuation.yield(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is only valid for the duration of this call, so the move
        // into place happens here rather than back on the async side. A non-200
        // still downloads its body to a temp file, so check the status first and
        // let it be discarded.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = HFSnapshotDownloadError("\(label): HTTP \(http.statusCode)")
            return
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: target)
            try fm.moveItem(at: location, to: target)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            continuation.finish(throwing: failure)
            return
        }
        // Task cancellation reaches us as an NSURLError; re-surface it as the
        // structured-concurrency error the caller's `Task.checkCancellation`
        // would have thrown.
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
            continuation.finish(throwing: CancellationError())
        } else {
            continuation.finish(throwing: error)
        }
    }
}
