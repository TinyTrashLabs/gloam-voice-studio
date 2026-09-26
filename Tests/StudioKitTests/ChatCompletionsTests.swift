import EngineKit
import XCTest
@testable import StudioKit

final class ChatCompletionsTests: XCTestCase {
    func testDecodeMinimalRequest() throws {
        let json = """
        {"model":"x","messages":[{"role":"system","content":"be brief"},
        {"role":"user","content":"hi"}],"temperature":0.5,"max_tokens":64}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        let (chat, temporary) = try req.toChatRequest()
        XCTAssertTrue(temporary.isEmpty)
        XCTAssertNil(chat.imageURLs)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages[0].role, .system)
        XCTAssertEqual(chat.temperature, 0.5)
        XCTAssertEqual(chat.maxTokens, 64)
        XCTAssertTrue(chat.disableThinking)   // server default
    }

    func testEncodeResponseShape() throws {
        let resp = ChatCompletionResponse(
            model: "gemma4-e4b",
            content: "Play that record.",
            promptTokens: 10, completionTokens: 5)
        let data = try JSONEncoder().encode(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["object"] as? String, "chat.completion")
        let choices = obj["choices"] as! [[String: Any]]
        let message = choices[0]["message"] as! [String: Any]
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(message["content"] as? String, "Play that record.")
        let usage = obj["usage"] as! [String: Any]
        XCTAssertEqual(usage["total_tokens"] as? Int, 15)
    }

    /// OpenAI vision shape: the last user message's content is an array of
    /// text and image_url parts. The text parts become the turn's content
    /// and each data: image lands in a temp file the engine can read.
    func testDecodeImageContentParts() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let json = """
        {"model":"gemma4-e4b","messages":[
          {"role":"system","content":"You are a Furby."},
          {"role":"user","content":[
             {"type":"text","text":"What do you see?"},
             {"type":"image_url","image_url":{"url":"data:image/png;base64,\(png.base64EncodedString())"}}
          ]}]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.messages[1].content, "What do you see?")
        XCTAssertEqual(req.messages[1].imageURLStrings.count, 1)
        let (chat, temporary) = try req.toChatRequest()
        defer { temporary.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(chat.messages[1].content, "What do you see?")
        XCTAssertEqual(chat.imageURLs?.count, 1)
        XCTAssertEqual(temporary, chat.imageURLs)
        XCTAssertEqual(try XCTUnwrap(chat.imageURLs?.first).pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(chat.imageURLs?.first)), png)
    }

    func testImagesOnEarlierTurnsAreIgnoredAndFileURLsPassThrough() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chat-img-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let json = """
        {"messages":[
          {"role":"user","content":[{"type":"text","text":"earlier"},
             {"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]},
          {"role":"assistant","content":"ok"},
          {"role":"user","content":[{"type":"image_url","image_url":{"url":"\(file.absoluteString)"}},
             {"type":"text","text":"now"}]}]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        let (chat, temporary) = try req.toChatRequest()
        XCTAssertTrue(temporary.isEmpty)          // a file: URL is used in place
        XCTAssertEqual(chat.imageURLs, [file])
        XCTAssertEqual(chat.messages.map(\.content), ["earlier", "ok", "now"])
    }

    func testBadImageURLIsRejected() throws {
        let json = """
        {"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com/x.png"}}]}]}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try req.toChatRequest()) { XCTAssertTrue($0 is ChatCompletionRequest.BadImage) }
        let missing = """
        {"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"file:///nonexistent/\(UUID().uuidString).png"}}]}]}
        """
        let req2 = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(missing.utf8))
        XCTAssertThrowsError(try req2.toChatRequest())
    }

    func testPlainStringContentRoundTrips() throws {
        let m = ChatCompletionRequest.Message(role: "user", content: "hi")
        let data = try JSONEncoder().encode(m)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["content"] as? String, "hi")
        XCTAssertEqual(try JSONDecoder().decode(ChatCompletionRequest.Message.self, from: data).content, "hi")
    }

    func testSamplerKnobsReachTheEngineRequest() throws {
        let json = """
        {"messages":[{"role":"user","content":"hi"}],"repetition_penalty":1.25,"repetition_context_size":64,
         "presence_penalty":0.4,"frequency_penalty":0.2,"top_k":40,"min_p":0.05}
        """
        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        let (chat, _) = try req.toChatRequest()
        XCTAssertEqual(chat.repetitionPenalty, 1.25)
        XCTAssertEqual(chat.repetitionContextSize, 64)
        XCTAssertEqual(chat.presencePenalty, 0.4)
        XCTAssertEqual(chat.frequencyPenalty, 0.2)
        XCTAssertEqual(chat.topK, 40)
        XCTAssertEqual(chat.minP, 0.05)
        // Unset knobs stay nil so the library defaults apply.
        let bare = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data("{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}".utf8))
        XCTAssertNil(try bare.toChatRequest().request.repetitionPenalty)
    }
}
