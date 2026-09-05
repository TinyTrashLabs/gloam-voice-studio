import XCTest
@testable import StudioKit

final class NonverbalTagCatalogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try json.write(to: dir.appendingPathComponent("added_tokens.json"),
                       atomically: true, encoding: .utf8)
    }

    /// A tokenizer's added tokens are mostly control tokens. Only the
    /// parenthesised ones are sounds a script may contain.
    func testOnlyParenthesisedTokensAreTags() throws {
        try write("""
        {"(laughs)": 3, "(sighs)": 4, "[S1]": 1, "<pad>": 0, "()": 9}
        """)
        XCTAssertEqual(NonverbalTagCatalog.parenthesised(inModelDirectory: dir),
                       ["(laughs)", "(sighs)"])
    }

    /// A model that isn't downloaded yet must not produce an empty picker
    /// presented as fact — callers need to tell "none" from "don't know", and
    /// both arrive here as an empty list they fall back from.
    func testAMissingFileIsEmptyRatherThanACrash() {
        XCTAssertTrue(NonverbalTagCatalog.parenthesised(inModelDirectory: dir).isEmpty)
    }

    func testMalformedJSONIsEmptyRatherThanACrash() throws {
        try write("{not json")
        XCTAssertTrue(NonverbalTagCatalog.parenthesised(inModelDirectory: dir).isEmpty)
    }
}

extension NonverbalTagCatalogTests {
    /// A two-word tag is a real token in the vocabulary and still unusable,
    /// because the script parser splits on whitespace before encoding. Offering
    /// it would mean offering to have the words read out loud.
    func testMultiWordTagsAreExcludedBecauseTheParserSplitsThem() throws {
        try write("""
        {"(laughs)": 1, "(clears throat)": 2, "(audience laughs)": 3, "(sighs)": 4}
        """)
        XCTAssertEqual(NonverbalTagCatalog.parenthesised(inModelDirectory: dir),
                       ["(laughs)", "(sighs)"])
    }

    func testUsableInAScriptNamesTheRule() {
        XCTAssertTrue(NonverbalTagCatalog.usableInAScript("(laughs)"))
        XCTAssertFalse(NonverbalTagCatalog.usableInAScript("(clears throat)"))
    }
}
