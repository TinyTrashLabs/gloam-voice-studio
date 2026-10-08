import XCTest
@testable import GVoiceKit

final class ReferenceSectionLanguageTests: XCTestCase {
    private let spanish = "A mí me gusta hablar el inglés en privado, no en las cámaras ni por ahí. No, no hay nada que te pueda decir lo más complicado."
    private let english = "I like to speak English in private, not in the cameras or anywhere. There is nothing that I can say that is the most complicated thing."

    func testSpanishAndEnglishAreTold() {
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "es", spanish))
        XCTAssertFalse(ReferenceSection.textIsPlausibleIn(language: "es", english))
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "es-MX", spanish))
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "en", english))
        XCTAssertFalse(ReferenceSection.textIsPlausibleIn(language: "en", spanish))
    }

    func testUnknownLanguageAndShortTextPass() {
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: nil, english))
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "ja", english))
        XCTAssertTrue(ReferenceSection.textIsPlausibleIn(language: "es", "Hola amigos"))
    }

    func testHeardInTheWrongLanguageFallsBackToTheSlicedTranscript() {
        let r = ReferenceSection.text(heard: english, transcript: spanish, cutSeconds: 7.6, start: 0, count: 100, total: 100, language: "es")
        XCTAssertTrue(r.approximate)
        XCTAssertEqual(r.text, spanish)
        let ok = ReferenceSection.text(heard: english, transcript: spanish, cutSeconds: 7.6, start: 0, count: 100, total: 100)
        XCTAssertFalse(ok.approximate)   // no language known: unchanged behaviour
    }

    func testLengthPlausibility() {
        XCTAssertTrue(ReferenceSection.lengthIsPlausible(spanish, seconds: 7.6))
        XCTAssertFalse(ReferenceSection.lengthIsPlausible("uno dos", seconds: 20))
        XCTAssertFalse(ReferenceSection.lengthIsPlausible(spanish, seconds: 1))
    }
}
