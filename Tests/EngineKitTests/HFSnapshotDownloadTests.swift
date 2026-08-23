import Foundation
import Network
import XCTest
@testable import EngineKit

/// Covers the per-byte half of `downloadHFSnapshot` — the part that replaced
/// `URLSession.download(from:)` so progress moves as bytes land instead of once
/// per completed file.
///
/// `downloadHFFile` is exercised against a real HTTP server bound to 127.0.0.1
/// rather than a stub, because the whole point of the change is that the URL
/// loading system's own `didWriteData` fires mid-transfer — a stub that hands
/// back invented counts would prove nothing. The HuggingFace half of
/// `downloadHFSnapshot` (tree listing, resolve URLs, the byte-weighted-else-
/// file-count total) still needs a live fetch and isn't exercised here.
final class HFSnapshotDownloadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Coalescing granularity

    func testCoalescerReportsOncePerMebibyte() {
        let start = ContinuousClock.now
        var c = HFProgressCoalescer(now: start)

        // Well inside both bounds: nothing worth reporting yet.
        XCTAssertFalse(c.shouldReport(64 * 1024, now: start + .milliseconds(10)))
        XCTAssertFalse(c.shouldReport(1 << 20 - 1, now: start + .milliseconds(20)))
        XCTAssertTrue(c.shouldReport(1 << 20, now: start + .milliseconds(30)))
        // The byte bound is measured from the last report, not from zero.
        XCTAssertFalse(c.shouldReport(1 << 20 + 1024, now: start + .milliseconds(40)))
        XCTAssertTrue(c.shouldReport(2 << 20, now: start + .milliseconds(50)))
    }

    /// A slow link must still tick, or a short stall bound would fire on a
    /// healthy download.
    func testCoalescerReportsOnTimeWhenBytesAreScarce() {
        let start = ContinuousClock.now
        var c = HFProgressCoalescer(now: start)

        XCTAssertFalse(c.shouldReport(1024, now: start + .milliseconds(249)))
        XCTAssertTrue(c.shouldReport(2048, now: start + .milliseconds(250)))
        XCTAssertFalse(c.shouldReport(3072, now: start + .milliseconds(400)))
        XCTAssertTrue(c.shouldReport(4096, now: start + .milliseconds(500)))
    }

    // MARK: - Transfer

    func testDownloadsEveryByteToTheTargetPath() async throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try LocalHTTPServer(body: payload)
        defer { server.stop() }
        let target = dir.appendingPathComponent("out.bin")

        try await downloadHFFile(from: server.url, to: target, label: "out.bin") { _ in }

        XCTAssertEqual(try Data(contentsOf: target), payload)
    }

    /// The point of the change: one file must report many times, not once. The
    /// counts are cumulative and monotonic, and the last one is the whole file.
    func testReportsCumulativeBytesDuringASingleFile() async throws {
        let payload = Data(repeating: 7, count: 8 << 20)   // 8 MiB
        let server = try LocalHTTPServer(body: payload, chunkSize: 64 << 10)
        defer { server.stop() }
        let target = dir.appendingPathComponent("big.bin")
        var reports: [Int64] = []

        try await downloadHFFile(from: server.url, to: target, label: "big.bin") {
            reports.append($0)
        }

        XCTAssertGreaterThan(reports.count, 1,
                             "didWriteData must fire mid-transfer, not once at the end")
        XCTAssertEqual(reports, reports.sorted(), "counts are cumulative")
        XCTAssertEqual(reports.last, Int64(payload.count))
        // Progress was visible well before the file finished.
        XCTAssertTrue(reports.contains { $0 < Int64(payload.count) })
        XCTAssertEqual(try Data(contentsOf: target).count, payload.count)
    }

    func testNonOKResponseThrowsAndLeavesNothingBehind() async throws {
        let server = try LocalHTTPServer(body: Data("nope".utf8), status: 404)
        defer { server.stop() }
        let target = dir.appendingPathComponent("missing.bin")

        do {
            try await downloadHFFile(from: server.url, to: target, label: "missing.bin") { _ in }
            XCTFail("expected a non-200 to throw")
        } catch let error as HFSnapshotDownloadError {
            XCTAssertTrue(error.message.contains("404"), error.message)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// Cancelling from the progress callback must abort the transfer and leave
    /// the target path untouched — a truncated file there would be treated as
    /// complete forever by the caller's already-present-at-expected-size skip.
    func testCancellationLeavesNoPartialFile() async throws {
        let payload = Data(repeating: 5, count: 16 << 20)
        let server = try LocalHTTPServer(body: payload, chunkSize: 64 << 10,
                                         chunkDelay: .milliseconds(5))
        defer { server.stop() }
        let target = dir.appendingPathComponent("cancelled.bin")

        do {
            try await downloadHFFile(from: server.url, to: target, label: "cancelled.bin") { written in
                if written > 0 { throw CancellationError() }
            }
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// Cancelling the surrounding Task (rather than throwing from the callback)
    /// must cancel the URLSessionDownloadTask, not merely abandon the await.
    func testTaskCancellationAbortsTheTransfer() async throws {
        let payload = Data(repeating: 5, count: 16 << 20)
        let server = try LocalHTTPServer(body: payload, chunkSize: 64 << 10,
                                         chunkDelay: .milliseconds(5))
        defer { server.stop() }
        let target = dir.appendingPathComponent("aborted.bin")
        let sawBytes = XCTestExpectation(description: "transfer started")

        let task = Task {
            try await downloadHFFile(from: server.url, to: target, label: "aborted.bin") { written in
                if written > 0 { sawBytes.fulfill() }
            }
        }
        await fulfillment(of: [sawBytes], timeout: 10)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected the cancelled transfer to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testOverwritesAnExistingFileAtTheTarget() async throws {
        let target = dir.appendingPathComponent("out.bin")
        try Data("stale".utf8).write(to: target)
        let payload = Data(repeating: 1, count: 1024)
        let server = try LocalHTTPServer(body: payload)
        defer { server.stop() }

        try await downloadHFFile(from: server.url, to: target, label: "out.bin") { _ in }

        XCTAssertEqual(try Data(contentsOf: target), payload)
    }
}

// MARK: - Local HTTP server

/// Thread-safe one-slot box, so the listener's state handler can hand a
/// failure reason back to the initializer waiting on the semaphore.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}

/// Minimal HTTP/1.1 server on 127.0.0.1, so the tests drive the real URL
/// loading system (and therefore real `didWriteData` callbacks) without
/// touching the network. Network.framework is a system framework — no new
/// package dependency.
private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hf-test-http")
    private let head: Data
    private let body: Data
    private let chunkSize: Int
    private let chunkDelay: Duration
    private(set) var url = URL(string: "http://127.0.0.1/")!

    init(body: Data, status: Int = 200, chunkSize: Int = 1 << 20,
         chunkDelay: Duration = .zero) throws {
        self.body = body
        self.chunkSize = chunkSize
        self.chunkDelay = chunkDelay
        let lines = [
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")",
            "Content-Length: \(body.count)",
            "Content-Type: application/octet-stream",
            "Connection: close",
            "", "",
        ]
        self.head = Data(lines.joined(separator: "\r\n").utf8)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)

        // Both handlers must be in place before `start`, or the first connection
        // can arrive with nowhere to go.
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.queue)
            self.readRequest(conn, accumulated: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        let failure = Box<String?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure.set("listener failed: \(error)")
                ready.signal()
            case .cancelled:
                failure.set("listener cancelled before it was ready")
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, failure.get() == nil,
              let port = listener.port?.rawValue, port != 0,
              let url = URL(string: "http://127.0.0.1:\(port)/asset.bin") else {
            listener.cancel()
            throw HFSnapshotDownloadError(
                "could not bind a local HTTP listener: \(failure.get() ?? "no port assigned")")
        }
        self.url = url
    }

    func stop() { listener.cancel() }

    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var acc = accumulated
            if let data { acc.append(data) }
            if acc.range(of: Data("\r\n\r\n".utf8)) != nil {
                conn.send(content: self.head, completion: .contentProcessed { _ in })
                self.sendBody(conn, from: 0)
            } else if error != nil || isComplete {
                conn.cancel()
            } else {
                self.readRequest(conn, accumulated: acc)
            }
        }
    }

    /// Sends one chunk per completion so the transfer is paced (and so a
    /// cancellation test has a window to cancel in) instead of dumped into the
    /// connection's buffer all at once.
    private func sendBody(_ conn: NWConnection, from offset: Int) {
        guard offset < body.count else { conn.cancel(); return }
        let end = min(offset + chunkSize, body.count)
        let slice = body.subdata(in: offset..<end)
        conn.send(content: slice, isComplete: end == body.count, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { conn.cancel(); return }
            if self.chunkDelay == .zero {
                self.sendBody(conn, from: end)
            } else {
                self.queue.asyncAfter(deadline: .now() + self.chunkDelay.seconds) {
                    self.sendBody(conn, from: end)
                }
            }
        })
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
