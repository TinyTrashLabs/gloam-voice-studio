import XCTest
@testable import StudioKit

final class PersonaPromptBuilderTests: XCTestCase {
    func testDefaultPromptUsesVoiceName() {
        let prompt = PersonaPromptBuilder.systemPrompt(voiceName: "Willow", persona: nil)
        XCTAssertTrue(prompt.contains("You are Willow"))
        XCTAssertTrue(prompt.contains(PersonaPromptBuilder.speakingRules))
    }

    func testPersonaPromptWins() {
        let persona = Persona(systemPrompt: "You are a grumpy lighthouse keeper.")
        let prompt = PersonaPromptBuilder.systemPrompt(voiceName: "Willow", persona: persona)
        XCTAssertTrue(prompt.contains("grumpy lighthouse keeper"))
        XCTAssertFalse(prompt.contains("You are Willow"))
        XCTAssertTrue(prompt.contains(PersonaPromptBuilder.speakingRules))
    }

    func testBlankPersonaFallsBackToDefault() {
        let persona = Persona(systemPrompt: "   \n ")
        let prompt = PersonaPromptBuilder.systemPrompt(voiceName: "Willow", persona: persona)
        XCTAssertTrue(prompt.contains("You are Willow"))
    }
}
