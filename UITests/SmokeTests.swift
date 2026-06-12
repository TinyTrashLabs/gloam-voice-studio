import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testScriptModeBatchGeneratesTakes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        // Defensive: dismiss consent sheet if present.
        let consentButton = app.buttons["consent-accept"]
        if consentButton.waitForExistence(timeout: 3) {
            consentButton.click()
        }

        // ── Step 1: Create "Script Voice" ────────────────────────────────────────
        let newVoiceButton = app.buttons["new-voice"].firstMatch
        XCTAssertTrue(newVoiceButton.waitForExistence(timeout: 10),
                      "new-voice toolbar button should exist")
        newVoiceButton.click()

        let nameField = app.textFields["voice-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "voice-name field should appear in editor sheet")
        nameField.click()
        nameField.typeText("Script Voice")

        let sampleRefButton = app.buttons["use-sample-ref"]
        XCTAssertTrue(sampleRefButton.waitForExistence(timeout: 5),
                      "use-sample-ref button should be visible in --uitest mode")
        sampleRefButton.click()

        let saveButton = app.buttons["voice-save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5),
                      "voice-save button should be enabled after name + ref are set")
        saveButton.click()

        // Select the voice in the sidebar.
        let voiceRow = app.staticTexts["Script Voice"].firstMatch
        XCTAssertTrue(voiceRow.waitForExistence(timeout: 5),
                      "sidebar should show 'Script Voice' after save")
        voiceRow.click()

        // ── Step 2: Switch to Script mode ────────────────────────────────────────
        // Segmented Picker segments surface as radioButtons on macOS.
        let scriptSegment = app.radioButtons["Script"].firstMatch
        XCTAssertTrue(scriptSegment.waitForExistence(timeout: 5),
                      "Script segment in studio-mode picker should exist. debugDescription:\n\(app.debugDescription)")
        scriptSegment.click()

        // ── Step 3: Add two lines ─────────────────────────────────────────────────
        let addLine = app.buttons["add-line"].firstMatch
        XCTAssertTrue(addLine.waitForExistence(timeout: 5),
                      "add-line button should be visible in Script mode")
        addLine.click()
        addLine.click()

        // ── Step 4: Type into both script-line-text fields ────────────────────────
        let fields = app.textFields.matching(identifier: "script-line-text")
        XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 5),
                      "Two script-line-text fields should exist after adding two lines")
        XCTAssertEqual(fields.count, 2,
                       "Should have exactly 2 script-line-text fields. debugDescription:\n\(app.debugDescription)")
        fields.element(boundBy: 0).click()
        fields.element(boundBy: 0).typeText("First line of the script.")
        fields.element(boundBy: 1).click()
        fields.element(boundBy: 1).typeText("Second line of the script.")

        // ── Step 5: Generate All ──────────────────────────────────────────────────
        let generateAll = app.buttons["generate-all"].firstMatch
        XCTAssertTrue(generateAll.waitForExistence(timeout: 5),
                      "generate-all button should be present")
        generateAll.click()

        // Wait for generation to finish: generate-all re-enables (isBatchRunning → false).
        let generateAllEnabled = NSPredicate(format: "isEnabled == true")
        expectation(for: generateAllEnabled, evaluatedWith: generateAll)
        waitForExpectations(timeout: 20)

        // ── Step 6: Expand both lines to reveal takes ─────────────────────────────
        let expandButtons = app.buttons.matching(identifier: "expand-line")
        let expandCount = expandButtons.count
        for i in 0..<expandCount {
            expandButtons.element(boundBy: i).click()
        }

        // ── Step 7: Assert at least one star-take button exists ───────────────────
        let starTake = app.buttons.matching(identifier: "star-take").firstMatch
        XCTAssertTrue(starTake.waitForExistence(timeout: 5),
                      "At least one star-take button should appear after batch generation. debugDescription:\n\(app.debugDescription)")

        // ── Step 8: Export button should be enabled ───────────────────────────────
        let exportBtn = app.buttons["script-export"].firstMatch
        XCTAssertTrue(exportBtn.waitForExistence(timeout: 5),
                      "script-export button should exist")
        XCTAssertTrue(exportBtn.isEnabled,
                      "script-export should be enabled once takes exist")
    }

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
