import XCTest
import ZIPFoundation
@testable import StudioKit

final class GVoiceTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    /// Stands in for a Supertonic style: the shape the app cares about is the
    /// two tensor blocks, not the floats.
    static let style = Data(#"{"style_ttl":{"dims":[1,50,256]},"style_dp":{"dims":[1,8,16]}}"#.utf8)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gvoice-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func manifest(_ pack: Data) throws -> GVoice.Manifest {
        let archive = try Archive(data: pack, accessMode: .read)
        var out = Data()
        _ = try archive.extract(archive["manifest.json"]!) { out.append($0) }
        return try JSONDecoder().decode(GVoice.Manifest.self, from: out)
    }

    private func members(_ pack: Data) throws -> Set<String> {
        Set(try Archive(data: pack, accessMode: .read).map(\.path))
    }

    // MARK: round trips

    func testExportImportRoundTrip() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1, 2, 3, 4]), refText: "hello there")
        let pack = try GVoice.export("cruz", from: lib)
        try lib.delete("cruz")
        let meta = try GVoice.import(pack, into: lib)
        XCTAssertEqual(meta.name, "Cruz")
        XCTAssertEqual(meta.slug, "cruz")
        XCTAssertEqual(meta.refText, "hello there")
        XCTAssertEqual(try Data(contentsOf: try lib.get("cruz").refURL), Data([1, 2, 3, 4]))
    }

    func testManifestCarriesTheCurrentVersion() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        XCTAssertEqual(try manifest(try GVoice.export("cruz", from: lib)).gvoice, 2)
    }

    // MARK: voices that are not recordings

    func testSaveWithoutReferenceAudio() throws {
        let meta = try lib.save(name: "Billie Frost", refWav: nil, refText: "",
                                engines: ["supertonic-3": ["style.json": Self.style]])
        XCTAssertEqual(meta.slug, "billie-frost")
        let entry = try lib.entry("billie-frost")
        XCTAssertNil(entry.refURL)
        XCTAssertNotNil(entry.engines["supertonic-3"]?["style.json"])
    }

    func testSaveWithNeitherAudioNorAssetsThrows() {
        XCTAssertThrowsError(try lib.save(name: "Empty", refWav: nil, refText: ""))
    }

    func testStyleOnlyPackRoundTrips() throws {
        _ = try lib.save(name: "Billie", refWav: nil, refText: "",
                         engines: ["supertonic-3": ["style.json": Self.style]])
        let pack = try GVoice.export("billie", from: lib)
        XCTAssertEqual(try members(pack), ["manifest.json", "engines/supertonic-3/style.json"])
        try lib.delete("billie")
        let meta = try GVoice.import(pack, into: lib)
        XCTAssertEqual(meta.slug, "billie")
        XCTAssertNil(try lib.entry("billie").refURL)
    }

    // MARK: source audio

    func testExportCarriesSourceAndEngines() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "hi",
                         engines: ["supertonic-3": ["style.json": Self.style]])
        let pack = try GVoice.export("cruz", from: lib)
        XCTAssertEqual(try members(pack),
                       ["manifest.json", "source/ref.wav", "engines/supertonic-3/style.json"])
        let m = try manifest(pack)
        XCTAssertEqual(m.source?["base"]?.audio, "source/ref.wav")
        XCTAssertEqual(m.engines?["supertonic-3"]?["base"], ["engines/supertonic-3/style.json"])
    }

    /// The defect that took gvoice to 2: a rendition of more than one file
    /// (lux-tts is window audio + its transcript) wrote every file into the zip
    /// but could name only one in the manifest, so import dropped the rest.
    func testMultiFileEngineRenditionSurvivesRoundTrip() throws {
        _ = try lib.save(
            name: "Cruz", refWav: Data([1]), refText: "hi",
            engines: ["lux-tts": ["ref.wav": Data([2]), "voice.json": Self.style]])
        let pack = try GVoice.export("cruz", from: lib)
        let listed = try manifest(pack).engines?["lux-tts"]?["base"] ?? []
        XCTAssertEqual(listed.sorted(),
                       ["engines/lux-tts/ref.wav", "engines/lux-tts/voice.json"])

        let other = VoiceLibrary(directory: dir.appendingPathComponent("other"))
        let meta = try GVoice.import(pack, into: other)
        let installed = try other.entry(meta.slug).engines["lux-tts"] ?? [:]
        XCTAssertEqual(Set(installed.keys), ["ref.wav", "voice.json"])
    }

    func testExportWithoutSourceOmitsAudio() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "hi",
                         engines: ["supertonic-3": ["style.json": Self.style]])
        let pack = try GVoice.export("cruz", from: lib, includeSource: false)
        XCTAssertFalse(try members(pack).contains("source/ref.wav"))
        XCTAssertTrue(try members(pack).contains("engines/supertonic-3/style.json"))
        XCTAssertEqual(try manifest(pack).source, [:])
    }

    // MARK: variants

    func testExportGathersEmotionVariants() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "calm")
        try lib.saveAt(slug: "cruz-hype", name: "Cruz hype", refWav: Data([2]), refText: "loud",
                       variantOf: "cruz")
        let pack = try GVoice.export("cruz", from: lib)
        XCTAssertEqual(try manifest(pack).variants, ["base", "hype"])
        XCTAssertTrue(try members(pack).contains("source/ref-hype.wav"))
    }

    func testImportRoundTripsVariants() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "calm")
        try lib.saveAt(slug: "cruz-hype", name: "Cruz hype", refWav: Data([2]), refText: "loud",
                       variantOf: "cruz")
        let pack = try GVoice.export("cruz", from: lib)
        try lib.delete("cruz")
        try lib.delete("cruz-hype")
        _ = try GVoice.import(pack, into: lib)
        XCTAssertEqual(try lib.resolve("cruz", emotion: .hype).meta.slug, "cruz-hype")
        XCTAssertEqual(try Data(contentsOf: try lib.get("cruz-hype").refURL), Data([2]))
    }

    func testVariantStyleFilenamesCarrySuffix() throws {
        _ = try lib.save(name: "Cruz", refWav: nil, refText: "",
                         engines: ["supertonic-3": ["style.json": Self.style]])
        try lib.saveAt(slug: "cruz-hype", name: "Cruz hype", refWav: nil, refText: "",
                       variantOf: "cruz", engines: ["supertonic-3": ["style.json": Self.style]])
        let m = try members(try GVoice.export("cruz", from: lib))
        XCTAssertTrue(m.contains("engines/supertonic-3/style.json"))
        XCTAssertTrue(m.contains("engines/supertonic-3/style-hype.json"))
    }

    // MARK: forward compatibility

    func testImportKeepsUnrecognisedEngine() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "hi",
                         engines: ["engine-from-2027": ["blob.bin": Data([9])]])
        let pack = try GVoice.export("cruz", from: lib)
        try lib.delete("cruz")
        _ = try GVoice.import(pack, into: lib)
        XCTAssertNotNil(try lib.entry("cruz").engines["engine-from-2027"]?["blob.bin"])
    }

    // MARK: rejections

    func testImportRejectsUnknownVersion() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"{"gvoice":99,"name":"X"}"#.utf8)),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            guard case .invalidArchive(let m) = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
            XCTAssertTrue(m.contains("unsupported"), m)
        }
    }

    func testImportRejectsPackWithoutManifest() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("meta.json", Data(#"{"name":"X"}"#.utf8)),
            ("ref.wav", Data([1])),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            guard case .invalidArchive(let m) = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
            XCTAssertTrue(m.contains("no manifest.json"), m)
        }
    }

    /// A dangling member reference degrades to "skip that one asset" (Rule
    /// 1/2's graceful-degradation philosophy), not a hard failure — as long as
    /// something else in the base variant is actually installable.
    func testImportSkipsDanglingSourceMemberWhenOtherAssetsExist() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"""
            {"gvoice":2,"name":"X","variants":["base"],
             "source":{"base":{"audio":"source/ref.wav"}},
             "engines":{"supertonic":{"base":["engines/supertonic/style.json"]}}}
            """#.utf8)),
            ("engines/supertonic/style.json", Self.style),
        ])
        let meta = try GVoice.import(pack, into: lib)
        XCTAssertNil(try lib.entry(meta.slug).refURL)
        XCTAssertNotNil(try lib.entry(meta.slug).engines["supertonic"]?["style.json"])
    }

    /// If EVERY asset in the base variant is dangling, there is nothing left
    /// to install — that still throws, just for "no base variant" rather than
    /// the specific dangling reference (which was silently skipped).
    func testImportThrowsWhenAllBaseAssetsAreDangling() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"""
            {"gvoice":2,"name":"X","variants":["base"],"source":{"base":{"audio":"source/ref.wav"}}}
            """#.utf8)),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            guard case .invalidArchive(let m) = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
            XCTAssertTrue(m.contains("no base variant"), m)
        }
    }

    /// Manifest paths come from a zip someone sent us.
    func testImportRejectsPathTraversal() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"""
            {"gvoice":2,"name":"X","variants":["base"],"engines":{"../../escape":{"base":["engines/x/y.json"]}}}
            """#.utf8)),
            ("engines/x/y.json", Data("{}".utf8)),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            guard case .invalidArchive(let m) = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
            XCTAssertTrue(m.contains("unsafe"), m)
        }
    }

    /// The variant KEY (not just the engine id) is attacker-controlled too —
    /// it used to flow unsanitized into a filesystem path via `saveAt`.
    func testImportRejectsPathTraversalViaVariantKey() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"""
            {"gvoice":2,"name":"X","variants":["base","../../escape"],
             "source":{"base":{"audio":"source/ref.wav"},
                       "../../escape":{"audio":"source/ref-escape.wav"}}}
            """#.utf8)),
            ("source/ref.wav", Data([1])),
            ("source/ref-escape.wav", Data([2])),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            guard case .invalidArchive(let m) = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
            XCTAssertTrue(m.contains("unsafe"), m)
        }
    }

    /// A malicious/malformed manifest can order `variants` however it likes —
    /// import must still resolve "base" first and refuse to write ANY variant
    /// if base turns out to be uninstallable, regardless of list order.
    func testImportIsAtomicWhenBaseFailsEvenIfListedLast() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"""
            {"gvoice":2,"name":"X","variants":["hype","base"],
             "source":{"hype":{"audio":"source/ref-hype.wav"}}}
            """#.utf8)),
            ("source/ref-hype.wav", Data([1])),
        ])
        XCTAssertThrowsError(try GVoice.import(pack, into: lib))
        // No orphaned "x-hype" directory left behind despite "hype" being listed
        // (and thus resolvable) before the failing "base".
        XCTAssertThrowsError(try lib.get("x-hype"))
    }

    /// `provenance` is opaque to this build but must not be dropped on
    /// import -> re-export — it's how a re-bake stays reproducible.
    func testProvenanceRoundTrips() throws {
        let pack = try GVoice.makeArchive(entries: [
            ("manifest.json", Data(#"""
            {"gvoice":2,"name":"Cruz","variants":["base"],
             "source":{"base":{"audio":"source/ref.wav"}},
             "provenance":{"source":"latent-inversion","config":{"seed":7}}}
            """#.utf8)),
            ("source/ref.wav", Data([1])),
        ])
        let meta = try GVoice.import(pack, into: lib)
        XCTAssertEqual(meta.provenance, .object([
            "source": .string("latent-inversion"),
            "config": .object(["seed": .number(7)]),
        ]))
        let reexported = try manifest(try GVoice.export(meta.slug, from: lib))
        XCTAssertEqual(reexported.provenance, meta.provenance)
    }

    /// An independently-named voice that merely LOOKS like a variant by slug
    /// (e.g. "dj-nova" next to "dj") must never be swept into "dj"'s export —
    /// only real variants (created via `saveAt`, carrying `variantOf`) count.
    func testExportDoesNotAdoptSlugCoincidentalSiblings() throws {
        _ = try lib.save(name: "Dj", refWav: Data([1]), refText: "")
        _ = try lib.save(name: "Dj Nova", refWav: Data([2]), refText: "")
        let pack = try GVoice.export("dj", from: lib)
        XCTAssertEqual(try manifest(pack).variants, ["base"])
        XCTAssertFalse(try members(pack).contains { $0.contains("nova") })
    }

    func testExportUnknownSlugThrows() {
        XCTAssertThrowsError(try GVoice.export("nope", from: lib)) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }

    func testImportGarbageThrowsInvalidArchive() {
        XCTAssertThrowsError(try GVoice.import(Data([0xDE, 0xAD, 0xBE, 0xEF]), into: lib)) {
            guard case .invalidArchive = $0 as? StudioError else {
                return XCTFail("expected invalidArchive, got \($0)")
            }
        }
    }

    func testImportCollisionThrowsVoiceExists() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        let pack = try GVoice.export("cruz", from: lib)
        XCTAssertThrowsError(try GVoice.import(pack, into: lib)) {
            XCTAssertEqual($0 as? StudioError, .voiceExists(slug: "cruz"))
        }
    }
}
