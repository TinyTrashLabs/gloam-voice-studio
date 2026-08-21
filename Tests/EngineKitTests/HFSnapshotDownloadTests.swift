import XCTest
@testable import EngineKit

/// Covers the streaming half of `downloadHFSnapshot` — the part that replaced
/// `URLSession.download(from:)` so progress moves per byte instead of per file.
/// The network half (tree listing, resolve URLs) needs a live fetch and isn't
/// exercised here.
final class HFSnapshotDownloadTests: XCTestCase {

    /// Stands in for `URLSession.AsyncBytes`: a byte sequence that can be told
    /// to fail partway, so the caller's partial-file cleanup is testable.
    private struct ByteStream: AsyncSequence {
        typealias Element = UInt8
        let bytes: [UInt8]
        var failAfter: Int? = nil

        struct Iterator: AsyncIteratorProtocol {
            let bytes: [UInt8]
            let failAfter: Int?
            var index = 0
            mutating func next() async throws -> UInt8? {
                if let failAfter, index >= failAfter {
                    throw HFSnapshotDownloadError("stream failed")
                }
                guard index < bytes.count else { return nil }
                defer { index += 1 }
                return bytes[index]
            }
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(bytes: bytes, failAfter: failAfter)
        }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWritesEveryByteInOrder() async throws {
        let payload = (0..<5_000).map { UInt8($0 % 251) }
        let url = dir.appendingPathComponent("out.bin")

        try await streamToFile(ByteStream(bytes: payload), at: url, bufferBytes: 1024) { _ in }

        XCTAssertEqual(try Data(contentsOf: url), Data(payload))
    }

    /// The point of the change: a single file must report many times, not once.
    func testReportsChunksAsBytesArrive() async throws {
        let payload = [UInt8](repeating: 7, count: 4_096)
        let url = dir.appendingPathComponent("chunked.bin")
        var chunks: [Int64] = []

        try await streamToFile(ByteStream(bytes: payload), at: url, bufferBytes: 1024) {
            chunks.append($0)
        }

        XCTAssertEqual(chunks, [1024, 1024, 1024, 1024])
        XCTAssertEqual(chunks.reduce(0, +), Int64(payload.count))
    }

    func testReportsTrailingPartialChunk() async throws {
        let payload = [UInt8](repeating: 3, count: 1_500)
        let url = dir.appendingPathComponent("tail.bin")
        var chunks: [Int64] = []

        try await streamToFile(ByteStream(bytes: payload), at: url, bufferBytes: 1024) {
            chunks.append($0)
        }

        XCTAssertEqual(chunks, [1024, 476])
    }

    func testEmptyBodyWritesEmptyFileAndReportsNothing() async throws {
        let url = dir.appendingPathComponent("empty.bin")
        var chunks: [Int64] = []

        try await streamToFile(ByteStream(bytes: []), at: url, bufferBytes: 1024) {
            chunks.append($0)
        }

        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    /// A mid-stream failure propagates, and the partial write lands only at the
    /// path we passed — never at a final destination — so the caller can delete
    /// it and the "already present at expected size" skip can't be fooled.
    func testStreamFailurePropagatesAndLeavesOnlyThePartialPath() async throws {
        let payload = [UInt8](repeating: 9, count: 4_096)
        let partial = dir.appendingPathComponent(".out.bin.partial")
        let target = dir.appendingPathComponent("out.bin")
        let stream = ByteStream(bytes: payload, failAfter: 2_000)

        do {
            try await streamToFile(stream, at: partial, bufferBytes: 1024) { _ in }
            XCTFail("expected the stream failure to propagate")
        } catch is HFSnapshotDownloadError {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        // Caller's cleanup path: removing the partial leaves nothing behind.
        try FileManager.default.removeItem(at: partial)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// Cancellation surfaces through the `onChunk` callback (where
    /// `downloadHFSnapshot` calls `Task.checkCancellation()`) and aborts the write.
    func testCancellationFromCallbackAbortsTheWrite() async throws {
        let payload = [UInt8](repeating: 1, count: 8_192)
        let url = dir.appendingPathComponent("cancelled.bin")
        var chunks = 0

        do {
            try await streamToFile(ByteStream(bytes: payload), at: url, bufferBytes: 1024) { _ in
                chunks += 1
                if chunks == 2 { throw CancellationError() }
            }
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(chunks, 2)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, 2_048, "write stops at the cancelling chunk")
    }
}
