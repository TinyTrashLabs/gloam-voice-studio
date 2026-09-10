import Foundation

/// Streams one HTTP response straight into a file, in whatever chunks the
/// network delivers.
///
/// It exists because `URLSession.bytes` is an `AsyncSequence` of `UInt8` — one
/// async resumption per BYTE. A 4GB checkpoint shard is four billion of them,
/// which pins a core for the whole download and caps throughput well below the
/// connection. A data-task delegate hands over whole chunks instead, and they
/// go to disk without ever passing through Swift a byte at a time.
///
/// Resume is the other half: the body is appended to whatever partial file is
/// already there, so a dropped multi-gigabyte download continues instead of
/// starting again.
final class StreamingFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct HTTPStatusError: LocalizedError {
        let status: Int
        let name: String
        var errorDescription: String? { "\(name): HTTP \(status)" }
    }

    /// Download `request` into `tmp`.
    ///
    /// `resumeFrom` is how many bytes of `tmp` are already a valid prefix — the
    /// caller has asked for `bytes=<resumeFrom>-`. A 206 appends to them; a 200
    /// means the server ignored the range and is sending the whole file, so
    /// they are discarded. Returns the file's size on disk when it finishes.
    static func run(_ request: URLRequest, to tmp: URL, resumeFrom: Int64, name: String,
                    onProgress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        if !FileManager.default.fileExists(atPath: tmp.path) {
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: tmp)
        let streamer = StreamingFileDownload(handle: handle, resumeFrom: resumeFrom,
                                             name: name, onProgress: onProgress)
        // A private session, because the delegate is per-download and
        // `URLSession.shared` has no delegate slot. The serial queue is what
        // lets the file writes below need no locking of their own.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: streamer, delegateQueue: queue)
        defer {
            session.finishTasksAndInvalidate()
            try? handle.close()
        }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                streamer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return streamer.written
    }

    private let handle: FileHandle
    private let resumeFrom: Int64
    private let name: String
    private let onProgress: @Sendable (Int64) -> Void
    fileprivate var continuation: CheckedContinuation<Void, Error>?
    /// Bytes on disk for this file, resumed prefix included.
    private(set) var written: Int64
    private var settled = false

    private init(handle: FileHandle, resumeFrom: Int64, name: String,
                 onProgress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.resumeFrom = resumeFrom
        self.name = name
        self.onProgress = onProgress
        self.written = resumeFrom
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 || status == 206 else {
            completionHandler(.cancel)
            settle(.failure(HTTPStatusError(status: status, name: name)))
            return
        }
        do {
            if status == 206, resumeFrom > 0 {
                // The body picks up where the file stops.
                try handle.seekToEnd()
            } else {
                // Whole file coming: anything already there is not a prefix
                // of it, whatever its length.
                try handle.truncate(atOffset: 0)
                written = 0
            }
        } catch {
            completionHandler(.cancel)
            settle(.failure(error))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            onProgress(written)
        } catch {
            dataTask.cancel()
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // A cancelled task is the caller cancelling, and must surface as
            // cancellation rather than as a download failure — the two mean
            // different things to the UI (one leaves the model retryable, the
            // other says something went wrong).
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                settle(.failure(CancellationError()))
            } else {
                settle(.failure(error))
            }
            return
        }
        do { try handle.synchronize() } catch { settle(.failure(error)); return }
        settle(.success(()))
    }
}
