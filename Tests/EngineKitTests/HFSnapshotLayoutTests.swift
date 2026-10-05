import XCTest
@testable import EngineKit

/// The network-free half of a snapshot download: nested `.mlmodelc` paths and what a prune may delete.
final class HFSnapshotLayoutTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hfsl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ relative: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ relative: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    // MARK: nested paths

    func testRecursiveTreeKeepsNestedModelPackageFilesAndDropsDirectories() throws {
        let tree = """
        [{"type":"file","path":"README.md","size":10},
         {"type":"directory","path":"coreml"},
         {"type":"directory","path":"coreml/talker0.mlmodelc"},
         {"type":"file","path":"coreml/talker0.mlmodelc/coremldata.bin","size":5},
         {"type":"file","path":"coreml/talker0.mlmodelc/weights/weight.bin","size":7},
         {"type":"file","path":"host/config.json"},
         {"type":"file","path":"../escape.bin","size":1},
         {"type":"file","path":"/abs.bin","size":1},
         {"type":"file","path":"coreml//x.bin","size":1}]
        """
        let files = try HFSnapshotLayout.files(inTree: Data(tree.utf8))
        XCTAssertEqual(files.map(\.path), ["README.md", "coreml/talker0.mlmodelc/coremldata.bin",
                                           "coreml/talker0.mlmodelc/weights/weight.bin", "host/config.json"])
        XCTAssertNil(files[3].size)
    }

    func testNestedPathLandsInsideTheDestinationAndResolvesOnHub() throws {
        let dest = URL(fileURLWithPath: "/tmp/Models/qwen3-0.6b-ane", isDirectory: true)
        let path = "coreml/talker0.mlmodelc/weights/weight.bin"
        let target = HFSnapshotLayout.target(for: path, in: dest)
        XCTAssertEqual(target.path, "/tmp/Models/qwen3-0.6b-ane/coreml/talker0.mlmodelc/weights/weight.bin")
        XCTAssertEqual(target.deletingLastPathComponent().lastPathComponent, "weights")
        XCTAssertEqual(HFSnapshotLayout.resolveURL(repo: "tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE", path: path)?.absoluteString,
                       "https://huggingface.co/tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE/resolve/main/" + path)
    }

    // MARK: prune safety

    func testPruneNeverTouchesVoicesFolder() throws {
        let dir = try tempDir()
        try write("coreml/a.mlmodelc/model.mil", in: dir)
        try write("coreml/stale.mlmodelc/model.mil", in: dir)
        try write("voices/narrator/ref.wav", in: dir)
        try write("voices/narrator/voice.json", in: dir)
        HFSnapshotLayout.prune(keeping: ["coreml/a.mlmodelc/model.mil"], under: dir)
        XCTAssertTrue(exists("coreml/a.mlmodelc/model.mil", in: dir))
        XCTAssertFalse(exists("coreml/stale.mlmodelc", in: dir), "stale repo files and their emptied folders go")
        XCTAssertTrue(exists("voices/narrator/ref.wav", in: dir))
        XCTAssertTrue(exists("voices/narrator/voice.json", in: dir))
    }

    func testRepoFolderOnlyPruneKeepsUserFilesOutsideRepoFolders() throws {
        let dir = try tempDir()
        try write("coreml/a.mlmodelc/model.mil", in: dir)
        try write("coreml/old.bin", in: dir)
        try write("notes.txt", in: dir)
        try write("scratch/take.wav", in: dir)
        try write("voices/v/ref.wav", in: dir)
        HFSnapshotLayout.prune(keeping: ["coreml/a.mlmodelc/model.mil", "README.md"], under: dir, onlyRepoFolders: true)
        XCTAssertFalse(exists("coreml/old.bin", in: dir), "inside a repo folder: the downloader's to clean")
        XCTAssertTrue(exists("coreml/a.mlmodelc/model.mil", in: dir))
        XCTAssertTrue(exists("notes.txt", in: dir))
        XCTAssertTrue(exists("scratch/take.wav", in: dir))
        XCTAssertTrue(exists("voices/v/ref.wav", in: dir))
    }

    func testDefaultPruneStillRemovesTopLevelStaleFilesButKeepsNamedFiles() throws {
        let dir = try tempDir()
        try write("model.safetensors", in: dir)
        try write("old.onnx", in: dir)
        try write("libkeep.dylib", in: dir)
        HFSnapshotLayout.prune(keeping: ["model.safetensors"], under: dir, keepNames: ["libkeep.dylib"])
        XCTAssertTrue(exists("model.safetensors", in: dir))
        XCTAssertFalse(exists("old.onnx", in: dir))
        XCTAssertTrue(exists("libkeep.dylib", in: dir))
    }
}
