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
        let chat = req.toChatRequest()
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
}
