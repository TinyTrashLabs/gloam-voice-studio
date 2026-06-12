import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testCreateVoiceGeneratePlayHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        // Defensive: if consent sheet appears (should be pre-accepted in --uitest mode),
        // dismiss it so the rest of the test can proceed.
        let consentButton = app.buttons["consent-accept"]
        if consentButton.waitForExistence(timeout: 3) {
            consentButton.click()
        }

        // ── Step 1: Create a new voice ────────────────────────────────────────────
        // Use .firstMatch to handle cases where the accessibility tree duplicates
        // toolbar button identifiers (e.g. toolbar + menu representation).
        let newVoiceButton = app.buttons["new-voice"].firstMatch
        XCTAssertTrue(newVoiceButton.waitForExistence(timeout: 10),
                      "new-voice toolbar button should exist")
        newVoiceButton.click()

        let nameField = app.textFields["voice-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "voice-name field should appear in editor sheet")
        nameField.click()
        nameField.typeText("Test Voice")

        let sampleRefButton = app.buttons["use-sample-ref"]
        XCTAssertTrue(sampleRefButton.waitForExistence(timeout: 5),
                      "use-sample-ref button should be visible in --uitest mode")
        sampleRefButton.click()

        let saveButton = app.buttons["voice-save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5),
                      "voice-save button should be enabled after name + ref are set")
        saveButton.click()

        // ── Step 2: Select the voice row in the sidebar ───────────────────────────
        // The sidebar shows the voice display NAME.
        let voiceRow = app.staticTexts["Test Voice"]
        XCTAssertTrue(voiceRow.waitForExistence(timeout: 5),
                      "sidebar should show 'Test Voice' after save")
        voiceRow.click()

        // ── Step 3: Type text and generate ────────────────────────────────────────
        // TextEditor exposes as textViews in XCUITest.
        let editor = app.textViews["line-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5),
                      "line-editor TextEditor should exist in the studio")
        editor.click()
        editor.typeText("Hello from the smoke test.")

        let generateButton = app.buttons["generate"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 5),
                      "generate button should be present")
        generateButton.click()

        // ── Step 4: Wait for variant badge A (fake model is fast; 15 s headroom) ──
        let badge = app.staticTexts["variant-badge-A"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15),
                      "variant-badge-A should appear after generation completes")

        // If a generation-error appeared instead, surface it for diagnosis.
        let errorText = app.staticTexts["generation-error"]
        if errorText.exists {
            XCTFail("Generation error: \(errorText.value as? String ?? errorText.label)")
        }

        // ── Step 5: Play variant A ────────────────────────────────────────────────
        let playButton = app.buttons["play-A"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 5),
                      "play-A button should appear alongside variant card")
        playButton.click()

        // ── Step 6: Open history and assert the line appears ──────────────────────
        let historyButton = app.buttons["open-history"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 5),
                      "open-history button should be in the studio toolbar")
        historyButton.click()

        // history-list may surface as an outline, table, or list depending on macOS.
        // Try outline first, then table, then fall through to a direct text search.
        let historyOutline = app.outlines["history-list"].firstMatch
        let historyTable  = app.tables["history-list"].firstMatch
        _ = historyOutline.waitForExistence(timeout: 5) || historyTable.waitForExistence(timeout: 1)

        // The definitive assertion: the typed text must appear somewhere in the history sheet.
        let textPredicate = NSPredicate(format: "value CONTAINS 'Hello from the smoke'")
        let labelPredicate = NSPredicate(format: "label CONTAINS 'Hello from the smoke'")
        let combined = NSCompoundPredicate(orPredicateWithSubpredicates: [textPredicate, labelPredicate])

        let historyEntry = app.staticTexts.containing(combined).firstMatch
        XCTAssertTrue(
            historyEntry.waitForExistence(timeout: 5),
            "History list should contain the generated line text. debugDescription:\n\(app.debugDescription)"
        )
    }
}
