import EngineKit
import Foundation
import Hummingbird

/// Mirrors backends.FISH_NOTICE in the Python engine — served on 403s.
public let fishLicenseNotice =
    "Fish S2-Pro weights are under the Fish Audio Research License: research and "
    + "personal/non-commercial use only. Commercial use requires a license from "
    + "business@fish.audio. By enabling this backend you confirm your use is personal."

/// FastAPI-compatible HTTP error: serializes as {"detail": "<message>"}.
struct APIError: Error {
    let status: HTTPResponse.Status
    let detail: String
}

extension APIError: HTTPResponseError {
    func response(from request: Request, context: some RequestContext) throws -> Response {
        let body = try JSONEncoder().encode(["detail": detail])
        let buffer = ByteBuffer(data: body)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.contentLength] = String(buffer.readableBytes)
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: buffer))
    }
}

struct HealthResponse: Codable, ResponseEncodable {
    let ok: Bool
    let engine: String
    let loaded: Bool
    let memGb: Double
    let honorsTags: Bool
    let loadedBackends: [String]
}

struct VoicesResponse: Codable, ResponseEncodable { let voices: [VoiceMeta] }
struct OkResponse: Codable, ResponseEncodable { let ok: Bool }

struct VoiceCreateRequest: Codable {
    let name: String
    let refAudio: String          // base64 wav
    let refText: String?
}

struct VoiceUpdateRequest: Codable {
    let name: String?
    let refAudio: String?         // base64 wav, replaces ref.wav
    let refText: String?
}

struct VoiceImportRequest: Codable {
    let data: String              // base64 .gvoice zip
}

struct SpeechRequest: Codable {
    let input: String
    let model: String?
    let voice: String?
    let speaker: String?
    let instruct: String?
    let language: String?
    let temperature: Float?
    let top_p: Float?
    let top_k: Int?
    let repetition_penalty: Float?
    let response_format: String?
}

/// Everything the HTTP layer needs. The engine and stores are owned by the
/// app; the server only borrows them.
public struct APIDependencies: Sendable {
    public let engine: GloamEngine
    public let voices: VoiceLibrary
    public let defaultBackend: BackendID
    public let defaultLLM: LLMBackendID?
    public let log: APILog
    /// Bounds TTS (and other GPU) work. Separate from `llmGate` so a chat and a synth
    /// can be admitted at once — the engine then interleaves them safely on the GPU
    /// (a track-select no longer waits behind a 20s voice synth). Each gate still
    /// serializes its own kind (never two synths or two chats concurrently).
    public let gate: RequestGate
    public let llmGate: RequestGate

    public init(engine: GloamEngine, voices: VoiceLibrary, defaultBackend: BackendID,
                defaultLLM: LLMBackendID? = nil,
                log: APILog = APILog(),
                gate: RequestGate = RequestGate(maxConcurrent: 1, maxQueued: 3),
                llmGate: RequestGate = RequestGate(maxConcurrent: 1, maxQueued: 3)) {
        self.engine = engine
        self.voices = voices
        self.defaultBackend = defaultBackend
        self.defaultLLM = defaultLLM
        self.log = log
        self.gate = gate
        self.llmGate = llmGate
    }
}

// Make VoiceMeta ResponseEncodable so handlers can return it directly.
extension VoiceMeta: ResponseEncodable {}
