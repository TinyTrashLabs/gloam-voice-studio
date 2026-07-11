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
    // Chatterbox expressiveness. `emotion` picks a preset (flat|neutral|warm|
    // excited|hype); `exaggeration` (0–1) overrides it directly. Both no-ops on
    // backends without an emotion knob (Qwen). Extra fields, so the endpoint stays
    // OpenAI-compatible for clients that don't send them.
    let emotion: String?
    let exaggeration: Float?
    // Upper bound on the resolved exaggeration (Chatterbox). Lets a client keep an
    // expressive per-line `emotion` dial while capping the knob below the range
    // where Chatterbox timbre degrades. nil = no cap. No-op on backends without an
    // exaggeration knob.
    let exaggeration_ceiling: Float?
    let speed: Float?
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
    public let gate: RequestGate
    /// Slug of the library voice that answers `/v1/audio/speech` requests
    /// which don't name a `voice` ("" = none — today's raw-backend behavior).
    /// A closure, not a captured value, so flipping the Settings picker takes
    /// effect on the NEXT request without restarting the server — same
    /// resolver-closure shape as EngineKit's model-path providers.
    public let defaultVoice: @Sendable () -> String
    /// Raw `BackendID` that answers `/v1/audio/speech` requests which don't
    /// name a `model` ("" or unknown = fall through to `defaultBackend`).
    /// Live-read like `defaultVoice` so the Settings picker applies to the
    /// next request with no server restart.
    public let defaultModel: @Sendable () -> String

    public init(engine: GloamEngine, voices: VoiceLibrary, defaultBackend: BackendID,
                defaultLLM: LLMBackendID? = nil,
                log: APILog = APILog(),
                gate: RequestGate = RequestGate(maxConcurrent: 1, maxQueued: 3),
                defaultVoice: @escaping @Sendable () -> String = { "" },
                defaultModel: @escaping @Sendable () -> String = { "" }) {
        self.engine = engine
        self.voices = voices
        self.defaultBackend = defaultBackend
        self.defaultLLM = defaultLLM
        self.log = log
        self.gate = gate
        self.defaultVoice = defaultVoice
        self.defaultModel = defaultModel
    }
}

// Make VoiceMeta ResponseEncodable so handlers can return it directly.
extension VoiceMeta: ResponseEncodable {}
