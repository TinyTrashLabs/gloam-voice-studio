import XCTest
@testable import EngineKit

/// File-layout resolution for the sherpa-onnx Pocket bundle — pure filesystem
/// logic, no weights or dylib needed. The int8 tarball mixes precisions (fp32
/// encoder beside int8 everything else), which is exactly the case the
/// per-role candidate lists exist for.
final class PocketTTSTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-tts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func touch(_ names: [String]) throws {
        for n in names {
            try Data().write(to: dir.appendingPathComponent(n))
        }
    }

    /// The real int8-2026-01-26 bundle layout, dylib included.
    private let int8Bundle = [
        "lm_flow.int8.onnx", "lm_main.int8.onnx", "encoder.onnx", "decoder.int8.onnx",
        "text_conditioner.onnx", "vocab.json", "token_scores.json",
        "libsherpa-onnx-c-api.dylib",
    ]

    func testCompleteInt8BundleHasNothingMissing() throws {
        try touch(int8Bundle)
        XCTAssertNil(PocketTTS.missingModelFile(in: dir))
    }

    func testFp32BundleResolvesToo() throws {
        try touch(["lm_flow.onnx", "lm_main.onnx", "encoder.onnx", "decoder.onnx",
                   "text_conditioner.onnx", "vocab.json", "token_scores.json",
                   "libsherpa-onnx-c-api.dylib"])
        XCTAssertNil(PocketTTS.missingModelFile(in: dir))
    }

    func testInt8PreferredOverFp32WhenBothPresent() throws {
        try touch(["lm_main.int8.onnx", "lm_main.onnx"])
        XCTAssertEqual(PocketTTS.resolve(role: "lm_main", in: dir)?.lastPathComponent,
                       "lm_main.int8.onnx")
    }

    func testMissingGraphIsReportedByRole() throws {
        try touch(int8Bundle.filter { !$0.hasPrefix("lm_main") })
        XCTAssertEqual(PocketTTS.missingModelFile(in: dir), "lm_main")
    }

    func testMissingDylibIsReported() throws {
        // Weights alone don't run anything — the fetch script drops the runtime
        // beside them, and completeness must insist on it.
        try touch(int8Bundle.filter { $0 != "libsherpa-onnx-c-api.dylib" })
        XCTAssertEqual(PocketTTS.missingModelFile(in: dir), "libsherpa-onnx-c-api.dylib")
    }
}
