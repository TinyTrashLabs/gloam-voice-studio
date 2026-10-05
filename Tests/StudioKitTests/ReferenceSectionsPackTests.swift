import XCTest
@testable import GVoiceKit
@testable import StudioKit
import EngineKit

/// Engine sections live in the pack: chosen once at prep time, exported, imported byte for byte, and
/// never re-picked while the master hash matches.
final class ReferenceSectionsPackTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!
    var dir2: URL!
    var lib2: VoiceLibrary!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sections-\(UUID().uuidString)")
        dir = root.appendingPathComponent("a"); dir2 = root.appendingPathComponent("b")
        lib = VoiceLibrary(directory: dir); lib2 = VoiceLibrary(directory: dir2)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private let words = "alpha beta gamma delta. epsilon zeta eta theta. iota kappa lambda mu. nu xi omicron pi."

    private func master(seconds: Double) -> Data {
        ReferenceSection.wavData((0 ..< Int(seconds * 24_000)).map { i in
            let t = Double(i) / 24_000
            return t.truncatingRemainder(dividingBy: 0.9) < 0.6 ? 0.3 * Float(sin(2 * .pi * 180 * t)) : 0
        }, sampleRate: 24_000)
    }

    private func files(_ l: VoiceLibrary, _ engine: String) throws -> [String: Data] {
        let urls = try l.entry("cruz").engines[engine] ?? [:]
        return try urls.mapValues { try Data(contentsOf: $0) }
    }

    func testSectionsAreChosenOnceStoredAndTravelByteForByte() async throws {
        _ = try lib.save(name: "Cruz", refWav: master(seconds: 70), refText: words)
        let written = await lib.prepareSections("cruz")
        XCTAssertEqual(Set(written), ["lux-tts", "pocket-tts"])

        let lux = try files(lib, "lux-tts"), pocket = try files(lib, "pocket-tts")
        XCTAssertNotNil(lux["ref.wav"]); XCTAssertNotNil(pocket["ref.wav"])
        let rendition = try JSONDecoder().decode(LuxReferenceWindow.Rendition.self, from: try XCTUnwrap(lux["voice.json"]))
        let d = try XCTUnwrap(rendition.derivedFrom)
        XCTAssertEqual(d.audio, "source/ref.wav")
        XCTAssertGreaterThan(d.endSeconds, d.startSeconds)
        XCTAssertEqual(d.sourceSha256, ReferenceSection.sha256Hex(try Data(contentsOf: try XCTUnwrap(try lib.entry("cruz").refURL))))
        XCTAssertFalse(rendition.text.isEmpty)
        XCTAssertEqual(d.by, "transcript-slice", "no recognizer here: the master's own transcript, sliced and stored")

        // "Works with" reflects the folders the pack actually has.
        let caps = lib.capabilities("cruz")
        XCTAssertTrue(caps.engines.isSuperset(of: ["lux-tts", "pocket-tts"]))

        // Export -> import: every section file comes back identical, and nothing is re-picked.
        let pack = try GVoice.export("cruz", from: lib)
        _ = try GVoice.import(pack, into: lib2)
        XCTAssertEqual(try files(lib2, "lux-tts"), lux)
        XCTAssertEqual(try files(lib2, "pocket-tts"), pocket)
        let again = await lib2.prepareSections("cruz")
        XCTAssertEqual(again, [], "present and the master hash matches: kept, not re-picked")
        XCTAssertEqual(try files(lib2, "lux-tts"), lux)
    }

    func testAReplacedMasterInvalidatesTheOldSections() async throws {
        _ = try lib.save(name: "Cruz", refWav: master(seconds: 70), refText: words)
        await lib.prepareSections("cruz")
        let before = try files(lib, "lux-tts")["ref.wav"]
        _ = try lib.update("cruz", refWav: master(seconds: 64))
        let rewritten = await lib.prepareSections("cruz")
        XCTAssertTrue(rewritten.contains("lux-tts"))
        XCTAssertNotEqual(try files(lib, "lux-tts")["ref.wav"], before)
    }

    func testAMasterThatFitsGetsNoSections() async throws {
        _ = try lib.save(name: "Cruz", refWav: master(seconds: 8), refText: words)
        let written = await lib.prepareSections("cruz")
        XCTAssertEqual(written, [])
    }

    /// A section is part of the pack: writing one is a new revision; keeping one is not.
    func testWritingASectionBumpsTheRevisionAndKeepingOneDoesNot() async throws {
        _ = try lib.save(name: "Cruz", refWav: master(seconds: 70), refText: words)
        let before = try lib.meta("cruz").revision ?? 0
        let written = await lib.prepareSections("cruz")
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(try lib.meta("cruz").revision, before + 1)
        let again = await lib.prepareSections("cruz")
        XCTAssertEqual(again, [])
        XCTAssertEqual(try lib.meta("cruz").revision, before + 1)
    }
}
