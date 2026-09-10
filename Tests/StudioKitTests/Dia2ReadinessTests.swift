import XCTest
import EngineKit
import SpeechKit
@testable import StudioKit

/// Getting a voice ready to be a Dia2 speaker.
///
/// Two independent things can be missing — a reference clip, and the word
/// timings baked from it — and the app asks the user before doing either. That
/// decision is this policy, kept out of the views so both surfaces (Studio's
/// single line, the Dialogue composer) ask the same question the same way.
final class Dia2ReadinessTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func wav() -> Data {
        let samples = (0..<24_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        return WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: 24_000)
    }

    /// A recorded voice: reference clip, no timings yet.
    private func makeRecordedVoice() throws -> String {
        try lib.save(name: "Cruz", refWav: wav(), refText: "a spoken line").slug
    }

    /// A preset pack: a speaker binding and no audio at all.
    private func makePresetVoice() -> String {
        let preset = PresetVoice(slug: "kokoro-af-heart", name: "Heart", engine: "kokoro",
                                 speaker: "af_heart", notes: "Warm.")
        PresetVoiceSeeder.seed(into: lib, catalog: [preset], version: 1)
        return preset.slug
    }

    // MARK: what a voice still needs

    func testARecordedVoiceWithNoTimingsNeedsAligning() throws {
        XCTAssertEqual(Dia2Alignment.readiness(of: try makeRecordedVoice(), in: lib),
                       .needsAlignment)
    }

    /// The unification: a preset has nothing to align, so the offer has to
    /// record a clip with its own engine first (`makeDiaCompatible`) rather
    /// than dead-ending on "no reference audio".
    func testAPresetVoiceNeedsAReferenceBeforeItCanBeAligned() {
        XCTAssertEqual(Dia2Alignment.readiness(of: makePresetVoice(), in: lib),
                       .needsReference)
    }

    func testASynthesizedReferenceLeavesOnlyTheAlignmentToDo() throws {
        let slug = makePresetVoice()
        try lib.writeEngineAsset(slug, engine: "dia2", file: "ref.wav", data: wav())
        XCTAssertEqual(Dia2Alignment.readiness(of: slug, in: lib), .needsAlignment)
    }

    /// Baked = the pack carries `engines/dia2/alignment.json`. This is the
    /// state that must never prompt again.
    func testAnAlignedVoiceIsBaked() throws {
        let slug = try makeRecordedVoice()
        try Dia2Alignment.store([AlignedWord(w: "a", start: 0, end: 0.2)], for: slug, in: lib)
        XCTAssertEqual(Dia2Alignment.readiness(of: slug, in: lib), .baked)
    }

    /// An empty cache is not a bake: `resolve` ignores it and realigns, so
    /// treating it as done would mean a voice that prompts for nothing and
    /// conditions on nothing.
    func testAnEmptyAlignmentIsNotABake() throws {
        let slug = try makeRecordedVoice()
        try Dia2Alignment.store([], for: slug, in: lib)
        XCTAssertEqual(Dia2Alignment.readiness(of: slug, in: lib), .needsAlignment)
    }

    func testAnUnknownVoiceNeedsAReference() {
        XCTAssertEqual(Dia2Alignment.readiness(of: "no-such-voice", in: lib), .needsReference)
    }

    // MARK: which transcriber does the aligning

    /// The bug this fixes: Dia2 alignment used to be built from the user's
    /// DICTATION engine preference, which defaults to Apple — and Apple has no
    /// word timings, so every Dia2 generate died on the protocol's default
    /// "This transcriber does not provide word-level timings". Whisper is the
    /// only engine that provides them, so the Dia2 path names it directly and
    /// takes no engine choice at all.
    func testTheDia2AlignerIsAlwaysWhisperBacked() {
        let aligner = Dia2Aligner.make(modelFolder: dir)
        let whisperBacked = (aligner as? WhisperWordAligner)?.transcriber is WhisperTranscriber
        XCTAssertTrue(whisperBacked)
    }

    /// A missing Whisper model is a fact the caller can act on (download it),
    /// so it is its own error rather than the transcriber's generic complaint.
    func testAligningWithoutTheWhisperModelReportsTheMissingModel() async {
        let aligner = Dia2Aligner.unavailable(variant: "openai_whisper-small")
        do {
            _ = try await aligner.align(audioURL: dir, transcript: nil)
            XCTFail("expected the missing-model error")
        } catch let error as Dia2AlignerError {
            XCTAssertEqual(error, .whisperModelMissing(variant: "openai_whisper-small"))
            XCTAssertTrue(error.localizedDescription.contains("Whisper"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: what the picker tells the user

    /// A ready voice carries no marker at all — the Dialogue picker must not
    /// decorate the common case.
    func testABakedVoiceNeedsNoSetupMarker() {
        XCTAssertNil(Dia2Readiness.baked.setupHint)
    }

    /// Both unready states are pickable, so both say so. They are not the same
    /// wait, though: aligning an existing clip is one Whisper pass, while a
    /// preset must first have its own engine record a clip — a model swap and
    /// a synthesis before the aligning even starts. The copy distinguishes
    /// them so the slower pick isn't a surprise.
    func testAnUnalignedVoiceOffersAPlainSetupMarker() throws {
        let hint = try XCTUnwrap(Dia2Readiness.needsAlignment.setupHint)
        XCTAssertFalse(hint.localizedCaseInsensitiveContains("record"))
    }

    func testAPresetSaysItHasToRecordFirst() throws {
        let hint = try XCTUnwrap(Dia2Readiness.needsReference.setupHint)
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("record"))
    }
}
