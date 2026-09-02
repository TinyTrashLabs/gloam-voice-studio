import XCTest
@testable import StudioKit

final class Dia2AlignmentTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private struct CountingAligner: WordAligning {
        let words: [AlignedWord]
        let calls = Counter()
        final class Counter: @unchecked Sendable { var value = 0 }
        func align(audioURL: URL, transcript: String?) async throws -> [AlignedWord] {
            calls.value += 1
            return words
        }
    }

    func testAlignsOnceThenReadsTheCache() async throws {
        _ = try lib.save(name: "Ava", refWav: Data([1, 2, 3]), refText: "hello there")
        let aligner = CountingAligner(words: [
            AlignedWord(w: "hello", start: 0, end: 0.4),
            AlignedWord(w: "there", start: 0.5, end: 0.9),
        ])

        let first = try await Dia2Alignment.resolve("ava", in: lib, using: aligner)
        XCTAssertEqual(first.map(\.w), ["hello", "there"])
        XCTAssertEqual(aligner.calls.value, 1)

        let second = try await Dia2Alignment.resolve("ava", in: lib, using: aligner)
        XCTAssertEqual(second, first)
        XCTAssertEqual(aligner.calls.value, 1, "second call must hit the cache")
    }

    /// The cache lives in the pack's engine directory, so the pack now declares
    /// dia2 support through the existing capability rule.
    func testCachingMarksThePackAsDia2Capable() async throws {
        _ = try lib.save(name: "Ava", refWav: Data([1]), refText: "hi")
        XCTAssertFalse(lib.capabilities("ava").supports(.dia2))
        _ = try await Dia2Alignment.resolve("ava", in: lib,
                                            using: CountingAligner(words: [
                                                AlignedWord(w: "hi", start: 0, end: 0.3)]))
        XCTAssertTrue(lib.capabilities("ava").supports(.dia2))
    }

    func testCorruptCacheRealignsRatherThanFailing() async throws {
        _ = try lib.save(name: "Ava", refWav: Data([1]), refText: "hi")
        let aligner = CountingAligner(words: [AlignedWord(w: "hi", start: 0, end: 0.3)])
        _ = try await Dia2Alignment.resolve("ava", in: lib, using: aligner)

        let path = dir.appendingPathComponent("ava/engines/dia2/alignment.json")
        try Data("not json".utf8).write(to: path)

        let recovered = try await Dia2Alignment.resolve("ava", in: lib, using: aligner)
        XCTAssertEqual(recovered.map(\.w), ["hi"])
        XCTAssertEqual(aligner.calls.value, 2)
    }

    func testAPackWithoutReferenceAudioCannotAlign() async throws {
        _ = try lib.save(name: "Preset", refWav: nil, refText: "",
                         engines: ["kokoro": ["voice.json": Data("{}".utf8)]])
        let aligner = CountingAligner(words: [])
        do {
            _ = try await Dia2Alignment.resolve("preset", in: lib, using: aligner)
            XCTFail("expected a missing-reference error")
        } catch {
            XCTAssertEqual(aligner.calls.value, 0)
        }
    }
}
