import XCTest
@testable import StudioKit

final class VoiceRowLabelTests: XCTestCase {
    private func meta(_ name: String, slug: String = "s", presetEngine: String? = nil,
                      tagline: String? = nil, notes: String? = nil) -> VoiceMeta {
        var m = VoiceMeta(name: name, slug: slug, refText: "", createdAt: "",
                          persona: tagline.map { Persona(systemPrompt: "", tagline: $0) },
                          notes: notes)
        if let presetEngine {
            m.provenance = .object(["preset": .object(["engine": .string(presetEngine),
                                                        "speaker": .string("x")])])
        }
        return m
    }

    func testKokoroPresetSplitsQualifierOntoEngineSubtitle() {
        let label = VoiceRowLabel(meta("Adam · American English", slug: "kokoro-am-adam",
                                       presetEngine: "kokoro", notes: "American English male, voicepack."))
        XCTAssertEqual(label, VoiceRowLabel(title: "Adam", subtitle: "Kokoro · American English"))
    }

    func testQualifierThatIsTheEngineFamilyShowsTheFullEngineName() {
        let label = VoiceRowLabel(meta("Aiden · Qwen", presetEngine: "qwen3-custom"))
        XCTAssertEqual(label, VoiceRowLabel(title: "Aiden", subtitle: "Qwen Custom"))
    }

    func testPresetWithoutQualifierShowsEngine() {
        XCTAssertEqual(VoiceRowLabel(meta("M1", presetEngine: "supertonic")).subtitle, "SuperTonic")
    }

    func testUserVoiceUsesTaglineThenNotesNeverSlug() {
        XCTAssertEqual(VoiceRowLabel(meta("Benson", slug: "benson",
                                          tagline: "late-night bartender from Mendoza")),
                       VoiceRowLabel(title: "Benson", subtitle: "late-night bartender from Mendoza"))
        XCTAssertEqual(VoiceRowLabel(meta("Cruz", slug: "cruz-old",
                                          notes: "Gravelly radio host. Recorded 2026.")).subtitle,
                       "Gravelly radio host")
        XCTAssertNil(VoiceRowLabel(meta("DJ Rocksteady", slug: "dj-rocksteady")).subtitle)
    }

    func testUnknownPresetEngineFallsBackToQualifier() {
        XCTAssertEqual(VoiceRowLabel(meta("Rachel · ElevenLabs", presetEngine: "elevenlabs")),
                       VoiceRowLabel(title: "Rachel", subtitle: "ElevenLabs"))
    }
}
