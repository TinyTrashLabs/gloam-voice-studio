import XCTest
@testable import GloamVoiceEditing

/// The recogniser writes numbers as digits ("4:30", "9"); a script says
/// them in words. Word matching normalises both sides to words first.
final class SpokenWordsTests: XCTestCase {
    private func w(_ s: String) -> [String] { SpokenWords.words(s) }

    func testCardinalsBecomeWords() {
        XCTAssertEqual(w("0 7 12 20 45"), ["zero", "seven", "twelve", "twenty", "forty", "five"])
        XCTAssertEqual(w("100 305 1000 9999"),
                       ["one", "hundred", "three", "hundred", "five", "one", "thousand",
                        "nine", "thousand", "nine", "hundred", "ninety", "nine"])
        XCTAssertEqual(w("1,200"), ["one", "thousand", "two", "hundred"])
        XCTAssertEqual(w("12345"), ["twelve", "thousand", "three", "hundred", "forty", "five"])
        XCTAssertEqual(w("2,500,000"), ["two", "million", "five", "hundred", "thousand"])
        XCTAssertEqual(w("1234567890"), ["1234567890"], "past 999,999,999 is left alone")
    }

    func testTimesBecomeWords() {
        XCTAssertEqual(w("at 4:30."), ["at", "four", "thirty"])
        XCTAssertEqual(w("4:05"), ["four", "oh", "five"])
        XCTAssertEqual(w("10:00"), ["ten", "o'clock"])
    }

    func testDecimalsBecomeWords() {
        XCTAssertEqual(w("3.5"), ["three", "point", "five"])
        XCTAssertEqual(w("12.05 miles"), ["twelve", "point", "zero", "five", "miles"])
        XCTAssertEqual(w("the end.Next"), ["the", "end", "next"])
        XCTAssertEqual(w("It cost 5. Then"), ["it", "cost", "five", "then"])
    }

    func testYearsReadAsWordsMatchTheirDigits() {
        for (digits, spoken) in [("1999", "nineteen ninety nine"), ("2026", "twenty twenty six"),
                                 ("1905", "nineteen oh five"), ("1900", "nineteen hundred"),
                                 ("1990", "nineteen ninety"), ("2010", "twenty ten"),
                                 ("1815", "eighteen fifteen"), ("2000", "twenty hundred")] {
            XCTAssertEqual(w(spoken), w(digits), spoken)
        }
    }

    func testPartialYearsStayAsSpoken() {
        XCTAssertEqual(w("nineteen"), ["nineteen"])
        XCTAssertEqual(w("nineteen oh"), ["nineteen", "oh"])
        XCTAssertEqual(w("twenty five"), ["twenty", "five"])
        XCTAssertEqual(w("nineteen five"), ["nineteen", "five"])
        XCTAssertNotEqual(w("nineteen twenty"), w("1926"), "a skipped digit must still show")
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "born in nineteen twenty", script: "born in 1926") < 1, true)
    }

    /// "chapters 11, 12" reads "eleven twelve"; a recogniser that writes it
    /// in words must not be folded to 1112 against a script with no such year.
    func testYearShapedNumbersThatAreNotYearsAreNotFalselyFlagged() {
        for (script, heard) in [("read chapters 11, 12 tonight", "read chapters eleven twelve tonight"),
                                ("pages 15 20 are missing", "pages fifteen twenty are missing"),
                                ("score twenty 20 was", "score twenty twenty was"),
                                ("chapters 20 20 apart", "chapters twenty twenty apart")] {
            XCTAssertEqual(RecordingCheck.scriptMatch(heard: heard, script: script), 1, script)
            XCTAssertEqual(RecordingCheck.transcriptCoverage(heard: heard, script: script), 1, script)
        }
    }

    func testAHeardYearStillFoldsWhenTheScriptHasIt() {
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "born in nineteen ninety nine", script: "born in 1999"), 1)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "in twenty twenty six", script: "in 2026"), 1)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "in nineteen ninety nine", script: "in nineteen ninety nine"), 1)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "chapters eleven twelve", script: "chapters 1112"), 1)
    }

    func testAGenuinelySkippedNumberIsStillFlagged() {
        XCTAssertLessThan(RecordingCheck.scriptMatch(heard: "born in nineteen twenty", script: "born in 1926"), 1)
        XCTAssertLessThan(RecordingCheck.scriptMatch(heard: "chapters eleven", script: "chapters 11, 12"), 1)
    }

    func testTimesWithAmPm() {
        XCTAssertEqual(w("4:30pm"), ["four", "thirty", "pm"])
        XCTAssertEqual(w("4pm"), ["four", "pm"])
        XCTAssertEqual(w("4:30 p.m."), ["four", "thirty", "pm"])
        XCTAssertEqual(w("9 A.M. sharp"), ["nine", "am", "sharp"])
        XCTAssertEqual(w("I am here"), ["i", "am", "here"])
    }

    func testMatchingAcrossNewForms() {
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "it was 3.5 miles in 1999", script: "it was three point five miles in nineteen ninety nine"), 1)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "see you at 4:30pm", script: "see you at four thirty p.m."), 1)
    }

    func testOrdinalsBecomeWords() {
        XCTAssertEqual(w("1st 2nd 3rd 4th 11th 21st 40th"),
                       ["first", "second", "third", "fourth", "eleventh", "twenty", "first", "fortieth"])
    }

    func testCurlyApostrophesAreStraightened() {
        XCTAssertEqual(w("You’ll"), ["you'll"])
    }

    func testMatchingIgnoresHowANumberWasWritten() {
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "leaves from platform 9", script: "leaves from platform nine"), 1)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "the meeting at 4:30", script: "the meeting at four thirty"), 1)
        XCTAssertEqual(RecordingCheck.transcriptCoverage(heard: "the meeting at 4:30", script: "the meeting at four thirty"), 1)
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "you’ll hear it", script: "you'll hear it"), 1)
    }

    /// The clone-time test line that tripped the check in the Simulator.
    func testTheQuestionTestLineMatchesItsDigitTranscript() {
        let line = VoiceQualifier.testLines[1]
        XCTAssertEqual(RecordingCheck.scriptMatch(heard: "Did you remember to call Maria about the meeting at 4:30?", script: line), 1)
    }
}
