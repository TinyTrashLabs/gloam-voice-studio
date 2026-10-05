import XCTest
import GVoiceKit
@testable import GVoiceProductionKit

final class ReferencePreparerTests: XCTestCase {
    func testStandardPreparationProducesPackWAVTranscriptAndProvenance() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let request = ReferencePreparationRequest(sourceURL: source, sourceIdentity: "owned fixture",
            transcript: "Hello there.", language: "en",
            recipe: .standard(segments: [.init(startSeconds: 0.05, endSeconds: 0.25)]))
        let result = try await ReferencePreparer(separator: nil).prepare(request)
        XCTAssertEqual(result.transcript, "Hello there.")
        XCTAssertEqual(String(data: result.wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(result.metrics.sampleRate, 24_000)
        XCTAssertEqual(result.metrics.channels, 1)
        guard case .object(let root) = result.provenance,
              case .object(let cleanup)? = root["referenceCleanup"] else { return XCTFail("cleanup provenance object") }
        XCTAssertEqual(cleanup["sourceIdentity"], .string("owned fixture"))
    }

    func testIsolationSeparatesEverySegmentBeforeJoining() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let separator = CountingSeparator()
        let recipe = ReferenceCleanupRecipe.isolateVocals(segments: [
            .init(startSeconds: 0, endSeconds: 0.1), .init(startSeconds: 0.2, endSeconds: 0.3)
        ])
        _ = try await ReferencePreparer(separator: separator).prepare(.init(
            sourceURL: source, transcript: "One. Two.", recipe: recipe))
        XCTAssertEqual(separator.calls, 2)
        XCTAssertTrue(separator.received.allSatisfy { $0.channelCount == 2 })
    }

    func testIsolationRequiresSeparatorAndTranscript() async throws {
        let source = try makeSource(); defer { try? FileManager.default.removeItem(at: source) }
        let recipe = ReferenceCleanupRecipe.isolateVocals(segments: [.init(startSeconds: 0, endSeconds: 0.1)])
        await XCTAssertThrowsErrorAsync { _ = try await ReferencePreparer(separator: nil).prepare(.init(sourceURL: source, transcript: "x", recipe: recipe)) }
        await XCTAssertThrowsErrorAsync { _ = try await ReferencePreparer(separator: nil).prepare(.init(sourceURL: source, transcript: "", recipe: .standard(segments: [.init(startSeconds: 0, endSeconds: 0.1)]))) }
    }

    func testStereoUpmixDuplicatesTheMonoChannel() {
        let mono = ReferenceAudioBuffer(sampleRate: 24_000, channels: [[0.1, -0.2, 0.3]])
        let up = NativeAudioProcessor.stereo(mono)
        XCTAssertEqual(up.channels, [[0.1, -0.2, 0.3], [0.1, -0.2, 0.3]])
        XCTAssertEqual(up.sampleRate, 24_000)
        let stereo = ReferenceAudioBuffer(sampleRate: 24_000, channels: [[1, 2], [3, 4]])
        XCTAssertEqual(NativeAudioProcessor.stereo(stereo), stereo)
        XCTAssertEqual(NativeAudioProcessor.mono(up), mono)
    }

    func testIsolationUpmixesAMonoSourceInsteadOfRefusing() async throws {
        let source = try makeSource(channels: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        let separator = CountingSeparator()
        let recipe = ReferenceCleanupRecipe.isolateVocals(segments: [.init(startSeconds: 0, endSeconds: 0.1)])
        _ = try await ReferencePreparer(separator: separator).prepare(.init(sourceURL: source, transcript: "One.", recipe: recipe))
        XCTAssertEqual(separator.calls, 1)
        let got = try XCTUnwrap(separator.received.first)
        XCTAssertEqual(got.channelCount, 2)
        XCTAssertEqual(got.channels[0], got.channels[1])
    }

    private func makeSource(channels: Int = 2) throws -> URL {
        let rate = 48_000, frames = 24_000
        let left = (0..<frames).map { Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate))) * 0.1 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gvoice-source-\(UUID().uuidString).wav")
        try NativeAudioProcessor.pcm16WAV(.init(sampleRate: rate, channels: Array(repeating: left, count: channels))).write(to: url)
        return url
    }
}

private final class CountingSeparator: VoiceStemSeparating, @unchecked Sendable {
    let backendIdentifier = "test"; let modelIdentifier = "test"
    private let lock = NSLock(); private(set) var received: [ReferenceAudioBuffer] = []
    var calls: Int { lock.withLock { received.count } }
    func isolateVocals(_ input: ReferenceAudioBuffer) async throws -> ReferenceAudioBuffer {
        lock.withLock { received.append(input) }; return input
    }
}

private func XCTAssertThrowsErrorAsync(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("expected error", file: file, line: line) } catch { }
}
