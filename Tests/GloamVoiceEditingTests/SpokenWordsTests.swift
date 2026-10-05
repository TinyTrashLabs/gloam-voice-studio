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
        XCTAssertEqual(w("12345"), ["12345"], "past 9999 is left alone")
    }

    func testTimesBecomeWords() {
        XCTAssertEqual(w("at 4:30."), ["at", "four", "thirty"])
        XCTAssertEqual(w("4:05"), ["four", "oh", "five"])
        XCTAssertEqual(w("10:00"), ["ten", "o'clock"])
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
