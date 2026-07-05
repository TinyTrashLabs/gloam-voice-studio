import EngineKit
import Foundation
import Hummingbird

#if canImport(Darwin)
import Darwin
#endif

public enum APIRouter {
    /// Peak RSS in GB, 2dp — macOS ru_maxrss is bytes (health-endpoint parity).
    static func memGb() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_maxrss) / 1e9 * 100).rounded() / 100
    }

    /// Write a server-side error line to stderr with a direct, unbuffered write(2)
    /// syscall. The host shell redirects the engine's stderr into a block-buffered
    /// file, so `print`/NSLog lines can sit unflushed for a long time — a direct
    /// FileHandle write bypasses that libc buffering and lands immediately. Every
    /// 5xx path calls this, so an on-device engine failure is NEVER silent (that
    /// invisibility is what made the brain's `gemma4-26b` 500s undiagnosable).
    static func logError(_ message: String) {
        FileHandle.standardError.write(Data("[studio] ERROR \(message)\n".utf8))
    }

    public static func build(_ deps: APIDependencies) -> Router<BasicRequestContext> {
        let router = Router()

        // CORS for external browser clients (the gloam.fm DJ app) that fetch
        // this loopback API cross-origin. The Studio UI is same-origin and
        // unaffected. Added before routes so it wraps every response and
        // answers the JSON POST preflight (OPTIONS). Allowlist only — note
        // `.oneOf` is exact-match, so `*.gloam.fm` subdomains aren't covered.
        router.add(middleware: CORSMiddleware(
            allowOrigin: .oneOf("https://gloam.fm", "https://gloam-app.pages.dev"),
            allowHeaders: [.contentType],
            allowMethods: [.get, .post, .patch, .delete, .options]))

        router.add(middleware: APILogMiddleware(log: deps.log))

        router.get("health") { _, _ in
            let loaded = await deps.engine.loadedBackend()
            return HealthResponse(
                ok: true,
                engine: deps.defaultBackend.rawValue,
                loaded: loaded == deps.defaultBackend,
                memGb: memGb(),
                honorsTags: deps.defaultBackend.spec.honorsTags,
                loadedBackends: loaded.map { [$0.rawValue] } ?? [])
        }

        router.get("voices") { _, _ in
            VoicesResponse(voices: deps.voices.list())
        }

        router.post("voices") { request, context in
            let req = try await request.decode(as: VoiceCreateRequest.self, context: context)
            guard !req.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(status: .badRequest, detail: "name is empty")
            }
            guard let raw = Data(base64Encoded: req.refAudio) else {
                throw APIError(status: .badRequest, detail: "refAudio is not valid base64")
            }
            return try mapStoreErrors {
                try deps.voices.save(name: req.name, refWav: raw, refText: req.refText ?? "")
            }
        }

        router.patch("voices/:slug") { request, context in
            let slug = try context.parameters.require("slug")
            let req = try await request.decode(as: VoiceUpdateRequest.self, context: context)
            var raw: Data? = nil
            if let b64 = req.refAudio, !b64.isEmpty {
                guard let decoded = Data(base64Encoded: b64) else {
                    throw APIError(status: .badRequest, detail: "refAudio is not valid base64")
                }
                raw = decoded
            }
            let name = req.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return try mapStoreErrors {
                try deps.voices.update(slug,
                                       name: (name?.isEmpty == false) ? name : nil,
                                       refText: req.refText, refWav: raw)
            }
        }

        router.delete("voices/:slug") { _, context in
            let slug = try context.parameters.require("slug")
            return try mapStoreErrors { () -> OkResponse in
                try deps.voices.delete(slug)
                return OkResponse(ok: true)
            }
        }

        router.get("voices/:slug/export") { _, context in
            let slug = try context.parameters.require("slug")
            let data = try mapStoreErrors { try GVoice.export(slug, from: deps.voices) }
            var headers = HTTPFields()
            headers[.contentType] = "application/zip"
            headers[.contentDisposition] = "attachment; filename=\"\(slug).gvoice\""
            headers[.contentLength] = String(data.count)
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(data: data)))
        }

        router.post("voices/import") { request, context in
            let req = try await request.decode(as: VoiceImportRequest.self, context: context)
            guard let raw = Data(base64Encoded: req.data) else {
                throw APIError(status: .badRequest, detail: "data is not valid base64")
            }
            return try mapStoreErrors { try GVoice.import(raw, into: deps.voices) }
        }

        router.get("voices/:slug/ref.wav") { _, context in
            let slug = try context.parameters.require("slug")
            let (_, refURL) = try mapStoreErrors { try deps.voices.get(slug) }
            let data = try Data(contentsOf: refURL)
            var headers = HTTPFields()
            headers[.contentType] = "audio/wav"
            headers[.contentLength] = String(data.count)
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(data: data)))
        }

        router.post("v1/chat/completions") { request, context in
            let start = Date()
            let req = try await request.decode(as: ChatCompletionRequest.self, context: context)
            guard let backend = req.model.flatMap(LLMBackendID.init(rawValue:)) ?? deps.defaultLLM else {
                throw APIError(status: .serviceUnavailable, detail: "no on-device LLM configured")
            }
            let chatReq = req.toChatRequest()
            guard !chatReq.messages.isEmpty else {
                throw APIError(status: .badRequest, detail: "messages is empty")
            }
            guard chatReq.messages.contains(where: { $0.role == .user }) else {
                throw APIError(status: .badRequest, detail: "no user message")
            }
            do {
                let result = try await deps.gate.run {
                    try await deps.engine.chat(backend: backend, request: chatReq)
                }
                deps.log.record(.init(
                    method: "POST", path: "/v1/chat/completions", status: 200,
                    model: backend.rawValue, voice: nil, instruct: nil,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)))
                let resp = ChatCompletionResponse(
                    model: backend.rawValue, content: result.text,
                    promptTokens: result.usage.promptTokens,
                    completionTokens: result.usage.completionTokens)
                let data = try JSONEncoder().encode(resp)
                return Response(status: .ok,
                                headers: [.contentType: "application/json"],
                                body: .init(byteBuffer: ByteBuffer(data: data)))
            } catch is RequestGate.Busy {
                throw APIError(status: .serviceUnavailable, detail: "server busy — try again")
            } catch EngineError.languageProviderUnavailable {
                throw APIError(status: .serviceUnavailable, detail: "no on-device LLM configured")
            } catch {
                // Catch-ALL. Previously only `EngineError` was caught, so a raw
                // MLX/model-load error (NOT an EngineError) fell through to
                // Hummingbird as a bodyless 500 with no server log — exactly why
                // the on-device brain's `gemma4-26b` failure was undiagnosable.
                // Now every failure is logged AND returns its real reason in the body.
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let detail = "chat failed for \(backend.rawValue): \(error)"
                logError("\(detail) (\(ms)ms)")
                throw APIError(status: .internalServerError, detail: detail)
            }
        }

        router.post("v1/audio/speech") { request, context in
            let start = Date()
            let req = try await request.decode(as: SpeechRequest.self, context: context)
            if (req.response_format ?? "wav") != "wav" {
                throw APIError(status: .badRequest,
                               detail: "only response_format=wav is supported")
            }
            guard !req.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(status: .badRequest, detail: "input is empty")
            }
            let backend = req.model.flatMap(BackendID.init(rawValue:)) ?? deps.defaultBackend
            let controls = backend.controls

            func blank(_ s: String?) -> Bool {
                (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if controls.instruct == .required && blank(req.instruct) {
                throw APIError(status: .badRequest, detail: "\(backend.rawValue) requires 'instruct'")
            }
            if !controls.presetSpeakers.isEmpty,
               blank(req.speaker) || !controls.presetSpeakers.contains(req.speaker ?? "") {
                throw APIError(status: .badRequest,
                               detail: "\(backend.rawValue) requires a preset 'speaker'")
            }

            // Resolve `voice` + `emotion` to an acted `<voice>-<emotion>` variant clip
            // when one exists (e.g. "ogre" + "excited" → the ogre-excited clip); else
            // fall back to the base voice — the "normal" read. `emotion` omitted or
            // "neutral" always uses the base. A variant clip already carries its
            // emotion, so the live knob is left neutral; on the base clip, `emotion`
            // still drives the model knob (chatterbox exaggeration / fish temperature).
            var refPath: String? = nil
            var refText: String? = nil
            var usedVariant = false
            if let voice = req.voice {
                let emo = req.emotion?.lowercased()
                let variant = (emo != nil && emo != "neutral") ? "\(voice)-\(emo!)" : nil
                if let variant, let found = try? deps.voices.get(variant) {
                    refPath = found.refURL.path
                    refText = found.meta.refText.isEmpty ? nil : found.meta.refText
                    usedVariant = true
                } else if let found = try? deps.voices.get(voice) {
                    refPath = found.refURL.path
                    refText = found.meta.refText.isEmpty ? nil : found.meta.refText
                }
            }
            let knobEmotion = usedVariant ? Emotion.neutral
                : (req.emotion.flatMap(Emotion.init(rawValue:)) ?? .neutral)
            do {
                let result: SynthesisResult
                let synthRefPath = refPath, synthRefText = refText
                do {
                    result = try await deps.gate.run {
                        try await deps.engine.synthesize(
                            backend: backend,
                            request: SynthesisRequest(
                                text: req.input, refAudioPath: synthRefPath, refText: synthRefText,
                                emotion: knobEmotion,
                                speed: req.speed ?? 1.0,
                                temperatureOverride: req.temperature,
                                exaggerationOverride: req.exaggeration,
                                instruct: req.instruct, speaker: req.speaker, language: req.language,
                                topP: req.top_p, topK: req.top_k, repetitionPenalty: req.repetition_penalty))
                    }
                } catch is RequestGate.Busy {
                    throw APIError(status: .serviceUnavailable, detail: "server busy — try again")
                }
                let wav = WAVEncoder.encode(pcm16: PCM16.data(from: result.samples),
                                            sampleRate: result.sampleRate)
                deps.log.record(.init(
                    method: "POST", path: "/v1/audio/speech", status: 200,
                    model: backend.rawValue, voice: req.voice, instruct: req.instruct,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)))
                return Response(status: .ok,
                                headers: [.contentType: "audio/wav"],
                                body: .init(byteBuffer: ByteBuffer(data: wav)))
            } catch EngineError.licenseAckRequired {
                throw APIError(status: .forbidden, detail: fishLicenseNotice)
            } catch EngineError.refAudioRequired(let b) {
                throw APIError(status: .badRequest,
                               detail: "backend '\(b.rawValue)' requires reference audio")
            } catch EngineError.instructRequired(let b) {
                throw APIError(status: .badRequest, detail: "\(b.rawValue) requires 'instruct'")
            } catch EngineError.speakerRequired(let b) {
                throw APIError(status: .badRequest, detail: "\(b.rawValue) requires a preset 'speaker'")
            } catch let error as EngineError {
                throw APIError(status: .internalServerError, detail: "\(error)")
            }
        }

        return router
    }

    /// StudioError → FastAPI-parity status + detail strings.
    static func mapStoreErrors<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as StudioError {
            switch error {
            case .invalidName(let name):
                throw APIError(status: .badRequest,
                               detail: "name '\(name)' produces an empty slug")
            case .voiceExists(let slug):
                throw APIError(status: .conflict, detail: "voice '\(slug)' already exists")
            case .voiceNotFound(let slug):
                throw APIError(status: .notFound, detail: "voice '\(slug)' not found")
            case .invalidArchive(let message):
                // "archive meta.json has no voice name" → pass through exactly.
                // "not a valid .gvoice archive: ..." → pass through (already prefixed by GVoice.import).
                // Anything else → add the prefix.
                if message.hasPrefix("not a valid .gvoice archive") || message == "archive meta.json has no voice name" {
                    throw APIError(status: .badRequest, detail: message)
                } else {
                    throw APIError(status: .badRequest,
                                   detail: "not a valid .gvoice archive: \(message)")
                }
            case .historyEntryNotFound(let id):
                throw APIError(status: .notFound,
                               detail: "history entry '\(id)' not found")
            case .invalidRefAudio(let message):
                throw APIError(status: .badRequest, detail: message)
            }
        }
    }
}

/// Logs method/path/status/duration for every request. The speech handler adds a
/// richer entry on success/503; this catches everything else (errors, health, CRUD)
/// and speech-endpoint errors (4xx/5xx thrown as APIError).
struct APILogMiddleware<Context: RequestContext>: RouterMiddleware {
    let log: APILog
    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        let start = ContinuousClock.now
        let isManagedRoute = request.uri.path == "/v1/audio/speech"
            || request.uri.path == "/v1/chat/completions"
        do {
            let response = try await next(request, context)
            if !isManagedRoute {
                let ms = Int(start.duration(to: .now) / .milliseconds(1))
                log.record(.init(method: "\(request.method)", path: request.uri.path,
                                 status: Int(response.status.code), durationMs: ms))
            }
            return response
        } catch {
            let apiError = error as? APIError
            let status = apiError?.status.code ?? 500
            log.record(.init(method: "\(request.method)", path: request.uri.path,
                             status: Int(status), note: apiError?.detail ?? "\(error)"))
            throw error
        }
    }
}
