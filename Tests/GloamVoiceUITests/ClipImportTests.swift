import XCTest
@testable import GloamVoiceUI

final class ClipImportTests: XCTestCase {
    private let sr = 24_000
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-import-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Speech-like: 200 ms bursts of a −16 dBFS tone with a quiet floor between.
    private func speech(seconds: Double, speechAmp: Float = 0.16, noiseAmp: Float = 0.0005) -> [Float] {
        var out: [Float] = []
        var rng = SystemRandomNumberGenerator()
        let n = Int(seconds * Double(sr))
        for i in 0..<n {
            let inBurst = (i / (sr / 5)) % 2 == 0
            let tone = inBurst ? speechAmp * Float(sin(Double(i) * 2 * .pi * 220 / Double(sr))) : 0
            out.append(tone + noiseAmp * Float.random(in: -1...1, using: &rng))
        }
        return out
    }

    private func wav(_ samples: [Float], name: String = "clip.wav") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try VoicePlayer.wavData(samples: samples, sampleRate: sr).write(to: url)
        return url
    }

    func testAGoodClipComesBackWithItsSamplesAndNoProblem() throws {
        let imported = try ClipImport.prepare(try wav(speech(seconds: 8)))
        XCTAssertEqual(imported.seconds, 8, accuracy: 0.3)
        XCTAssertEqual(Double(imported.samples.count) / Double(sr), imported.seconds, accuracy: 0.01)
        XCTAssertNil(imported.quality.fileProblem, "\(imported.quality)")
    }

    /// Imports need the same minimum a recording does: under 3 s is not a
    /// reference, it is a syllable.
    func testUnderThreeSecondsIsRefused() throws {
        XCTAssertThrowsError(try ClipImport.prepare(try wav(speech(seconds: 2)))) { error in
            guard case ClipImport.ImportError.tooShort = error else { return XCTFail("\(error)") }
        }
    }

    func testALongClipIsKeptWhole() throws {
        // The master is the whole clip; each engine picks its own section later.
        let imported = try ClipImport.prepare(try wav(speech(seconds: 150)))
        XCTAssertEqual(imported.seconds, 150, accuracy: 0.5)
        XCTAssertEqual(Double(imported.samples.count) / Double(sr), imported.seconds, accuracy: 0.01)
    }

    func testAQuietClipIsFlaggedInFileWords() throws {
        // −51 dBFS: past what levelling can rescue (a phone take sits near −36 and must pass).
        let imported = try ClipImport.prepare(try wav(speech(seconds: 8, speechAmp: 0.004)))
        let problem = try XCTUnwrap(imported.quality.fileProblem)
        XCTAssertTrue(problem.lowercased().contains("quiet"), problem)
        XCTAssertFalse(problem.lowercased().contains("phone"), "file wording, not mic wording: \(problem)")
    }

    func testAHugeFileIsRefusedBeforeItIsOpened() throws {
        let url = dir.appendingPathComponent("huge.wav")
        // Sparse file: the size is what is checked, nothing is decoded.
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: UInt64(ClipImport.maxFileBytes) + 1)
        try h.write(contentsOf: Data([0]))
        try h.close()
        XCTAssertThrowsError(try ClipImport.prepare(url)) { error in
            guard case ClipImport.ImportError.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testNotAudioIsRefusedWithAnUndecodableError() throws {
        let url = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClipImport.prepare(url)) { error in
            guard case ClipImport.ImportError.undecodable = error else { return XCTFail("\(error)") }
        }
    }
}

/// Which recogniser transcribes a take or an imported clip. Pure, so the
/// switch can be tested without either recogniser.
