import XCTest
@testable import StudioKit

final class PromptExpansionTests: XCTestCase {
    func testAllCasesHaveNonEmptyInstructionAndNoun() {
        for kind in [PromptExpansionKind.voiceDescription, .direction, .persona, .greeting] {
            XCTAssertFalse(kind.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "\(kind) must declare an instruction")
            XCTAssertFalse(kind.noun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "\(kind) must declare a noun")
        }
    }

    func testInstructionsAreDistinctPerKind() {
        let instructions = [PromptExpansionKind.voiceDescription, .direction, .persona, .greeting]
            .map(\.instruction)
        XCTAssertEqual(Set(instructions).count, instructions.count,
                        "each kind must have its own instruction, not a shared/copy-pasted one")
    }

    func testInstructionsAskForNoPreamble() {
        // Every template must explicitly tell the model not to add commentary —
        // otherwise ExpandButton would show "Sure, here's an expanded version:"
        // inline in the text field.
        for kind in [PromptExpansionKind.voiceDescription, .direction, .persona, .greeting] {
            XCTAssertTrue(kind.instruction.contains("ONLY"),
                          "\(kind) instruction must constrain the model to reply with ONLY the rewritten text")
        }
    }
}
