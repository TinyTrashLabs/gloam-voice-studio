import XCTest
@testable import VoiceFXKit

final class FXPresetTests: XCTestCase {
    func testAllBuiltInsLoad() {
        XCTAssertEqual(Set(FXPreset.builtInNames), ["demon", "glitch", "whisper"])
        for name in FXPreset.builtInNames {
            XCTAssertNotNil(FXPreset.builtIn(named: name), "\(name) failed to load")
        }
    }

    func testUnknownPresetReturnsNil() {
        XCTAssertNil(FXPreset.builtIn(named: "nope"))
    }

    /// The demon character is defined by formants dropping FURTHER than pitch.
    /// If this inverts, the preset stops sounding large and starts sounding
    /// like a chipmunk in a well.
    func testDemonDropsFormantsBelowPitch() throws {
        let demon = try XCTUnwrap(FXPreset.builtIn(named: "demon"))
        let pitch = try XCTUnwrap(demon.pitch)
        XCTAssertLessThan(pitch.transposeSemitones, 0)
        XCTAssertLessThan(pitch.formantSemitones, 0)
        XCTAssertLessThan(pitch.formantSemitones, pitch.transposeSemitones,
                          "formants must drop further than pitch")
    }

    func testDemonHasDetuneBranchAndLimiter() throws {
        let demon = try XCTUnwrap(FXPreset.builtIn(named: "demon"))
        XCTAssertNotNil(demon.detune, "the doubled voice is the core of the character")
        XCTAssertNotNil(demon.limiter, "the limiter is not optional in any preset")
    }

    func testEveryBuiltInHasALimiter() throws {
        for name in FXPreset.builtInNames {
            let preset = try XCTUnwrap(FXPreset.builtIn(named: name))
            XCTAssertNotNil(preset.limiter, "\(name) must protect the speaker")
        }
    }

    func testRoundTripsThroughJSON() throws {
        for name in FXPreset.builtInNames {
            let original = try XCTUnwrap(FXPreset.builtIn(named: name))
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(FXPreset.self, from: data)
            XCTAssertEqual(original, decoded, "\(name) did not survive a round trip")
        }
    }

    /// A runaway slider should make the Furby sound wrong, not fail the
    /// request — and must never make the reverb self-oscillate.
    func testOutOfRangeValuesClamp() throws {
        let json = """
        {"version":1,"name":"wild",
         "pitch":{"transposeSemitones":-99,"formantSemitones":200,"formantBaseHz":-5},
         "drive":{"preGain":999,"postGain":-5,"shape1":50,"shape2":-50},
         "reverb":{"feedback":1.8,"lowpassHz":99999,"mix":3.0},
         "limiter":{"ceiling":9.0,"releaseSeconds":0.0}}
        """.data(using: .utf8)!
        let preset = try JSONDecoder().decode(FXPreset.self, from: json).clamped()
        XCTAssertEqual(preset.pitch?.transposeSemitones, -36)
        XCTAssertEqual(preset.pitch?.formantSemitones, 36)
        XCTAssertEqual(preset.pitch?.formantBaseHz, 0)
        XCTAssertEqual(preset.drive?.preGain, 20)
        XCTAssertEqual(preset.drive?.postGain, 0)
        XCTAssertEqual(preset.drive?.shape1, 10)
        XCTAssertEqual(preset.drive?.shape2, -10)
        XCTAssertEqual(try XCTUnwrap(preset.reverb?.feedback), 0.99, accuracy: 1e-9)
        XCTAssertEqual(preset.reverb?.mix, 1.0)
        XCTAssertEqual(preset.limiter?.ceiling, 1.0)
        XCTAssertGreaterThan(try XCTUnwrap(preset.limiter?.releaseSeconds), 0)
    }

    /// A controller sending an unknown field must not break the request.
    func testUnknownFieldsAreTolerated() throws {
        let json = """
        {"version":1,"name":"custom","futureKnob":42,
         "pitch":{"transposeSemitones":-5,"formantSemitones":-2,"formantBaseHz":180}}
        """.data(using: .utf8)!
        let preset = try JSONDecoder().decode(FXPreset.self, from: json)
        XCTAssertEqual(preset.name, "custom")
        XCTAssertEqual(preset.pitch?.transposeSemitones, -5)
    }
}
