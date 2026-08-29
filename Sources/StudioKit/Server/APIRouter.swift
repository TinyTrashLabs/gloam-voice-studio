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
            allowHeaders: [.contentType, .authorization],
            allowMethods: [.get, .post, .patch, .delete, .options]))

        router.add(middleware: APILogMiddleware(log: deps.log))

        // Bearer-token auth for the LAN-exposed server. `authToken()` is a live
        // read (nil while loopback-only, non-nil once the app turns LAN mode
        // on) — same closure idiom as `defaultVoice`. Every route requires it
        // except `/health`, which stays open so a LAN health check needs no
        // credential.
        router.add(middleware: APIAuthMiddleware(authToken: deps.authToken))

        // MCP: agents (Claude Code, Cursor, …) get list_voices + speak at /mcp.
        MCPRoute.add(to: router, deps: deps)

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
            VoicesResponse(voices: deps.voices.list().map {
                APIVoice(meta: $0, capabilities: deps.voices.capabilities($0.slug))
            })
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
                // Utility-priority hop: model work must not outrank the host
                // app's audio pipeline (gloam-dj #297) — and because awaiting
                // escalates the awaited task to the WAITER's priority, the cap
                // has to start here at the route, not only inside the engine.
                let result = try await Task(priority: GloamEngine.modelWorkPriority) {
                    try await deps.gate.run {
                        try await deps.engine.chat(backend: backend, request: chatReq)
                    }
                }.value
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
            // Model precedence: request `model` → Settings → API server
            // "Default model" (live-read, `.migrating` so a retired persisted
            // raw value still resolves) → the Studio's own engine.
            let backend = req.model.flatMap(BackendID.init(rawValue:))
                ?? BackendID.migrating(rawValue: deps.defaultModel())
                ?? deps.defaultBackend
            let controls = backend.controls

            func blank(_ s: String?) -> Bool {
                (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if controls.instruct == .required && blank(req.instruct) {
                throw APIError(status: .badRequest, detail: "\(backend.rawValue) requires 'instruct'")
            }
            // Preset-speaker backends (Kokoro): the OpenAI-compat `voice` field IS the
            // voicepack name, so accept it as the speaker. An absent/unknown speaker
            // (e.g. the gloam brain sends a clone-style `voice` slug it can't satisfy)
            // falls back to the backend's default — its best-first `presetSpeakers.first`
            // — rather than 400, mirroring the clone path's `defaultVoice` fallback below.
            // Immutable (`let`) so it can be captured by the concurrent synthesize
            // closure below — a reassigned `var` can't cross that boundary.
            let effectiveSpeaker: String? = {
                let s = blank(req.speaker) ? req.voice : req.speaker
                // Only pure preset-voicepack backends (Kokoro, SuperTonic — no
                // instruct control) default a missing/unknown speaker to their best
                // voice. A backend that pairs a chosen identity with a Direction
                // (qwen3-custom, instruct != .none) must NOT silently substitute a
                // house voice — a missing speaker there is a 400 (speakerRequired),
                // not a synth as "Vivian". (#28 broadened the Kokoro fallback to all
                // preset backends and unintentionally swept in qwen3-custom.)
                if controls.instruct == .none, !controls.presetSpeakers.isEmpty,
                   blank(s) || !controls.presetSpeakers.contains(s ?? "") {
                    return controls.presetSpeakers.first
                }
                return s
            }()

            // Resolve `voice` + `emotion` to an acted `<voice>-<emotion>` variant clip
            // when one exists (e.g. "ogre" + "excited" → the ogre-excited clip); else
            // fall back to the base voice — the "normal" read. `emotion` omitted or
            // "neutral" always uses the base. A variant clip already carries its
            // emotion, so the live knob is left neutral; on the base clip, `emotion`
            // still drives the model knob (chatterbox exaggeration / fish temperature).
            // A request that omits `voice` entirely falls back to the Settings →
            // API server "Default voice", read live off `deps.defaultVoice()` so
            // flipping the picker applies to the next request with no server restart.
            //
            // CONTRACT (2026-08): on a cloning backend this endpoint NEVER
            // synthesizes without a resolved reference. It used to resolve the slug
            // with two `try?`s that threw the `voiceNotFound` away; when both missed
            // on a `voiceClone: .optional` backend (qwen Base, fish) refPath/refText
            // stayed nil, the planner had nothing to reject (`needsRefAudio` is false
            // there), and the model generated UNCONDITIONED — inventing a fresh random
            // speaker per request while returning 200 and logging a normal line naming
            // the voice the caller asked for. An unusable voice is now an explicit,
            // logged 4xx instead: silence about it is worse than a failed request.
            var refPath: String? = nil
            var refText: String? = nil
            var usedVariant = false
            // The library slug actually rendered, so the voice's own loudness
            // trim can be applied to the output below. Nil for preset/instruct
            // backends, whose `voice` is not a library slug at all.
            var trimSlug: String? = nil
            let defaultVoice = deps.defaultVoice()
            let effectiveVoice = req.voice ?? (defaultVoice.isEmpty ? nil : defaultVoice)
            // Baked engine rendition: a pack carrying assets for THIS backend
            // (e.g. Billie Frost's engines/supertonic/style.json) renders that
            // voice instead of a house preset. Variant rendition first, then
            // the voice's own (renditionStyleURL also walks variantOf → base).
            let styleURL: URL? = effectiveVoice.flatMap { voice in
                let emo = req.emotion?.lowercased()
                let variant = (emo != nil && emo != "neutral") ? "\(voice)-\(emo!)" : nil
                return variant.flatMap { deps.voices.renditionStyleURL($0, engine: backend.rawValue) }
                    ?? deps.voices.renditionStyleURL(voice, engine: backend.rawValue)
            }
            // Preset-speaker backends (kokoro/supertonic/qwen-custom) and
            // instruct-only ones (qwen-design) have `voiceClone == .none`: their
            // `voice` field is not a library slug at all, so an unknown one keeps
            // falling through to the preset default exactly as before.
            let clones = controls.voiceClone != .none
            if let voice = effectiveVoice {
                let emo = req.emotion?.lowercased()
                let variant = (emo != nil && emo != "neutral") ? "\(voice)-\(emo!)" : nil
                var resolved: (slug: String, meta: VoiceMeta, refURL: URL)? = nil
                if let variant, let found = try? deps.voices.get(variant) {
                    resolved = (variant, found.meta, found.refURL)
                    usedVariant = true
                } else if let found = try? deps.voices.get(voice) {
                    // An emotion-variant miss still falls back to the base voice —
                    // only a base miss is fatal.
                    resolved = (voice, found.meta, found.refURL)
                }
                if let resolved {
                    // An empty transcript is the same failure wearing a disguise on
                    // the backends whose clone path is conditioned on text as well as
                    // audio: a nil refText drops qwen Base out of its ICL branch into
                    // the same unconditioned generation. Backends that clone from
                    // audio alone (chatterbox, pocket, fish) still accept it.
                    if clones && backend.needsRefText && resolved.meta.refText.isEmpty {
                        logError("/v1/audio/speech: voice '\(resolved.slug)' has an empty"
                            + " refText (model \(backend.rawValue)) — refusing to"
                            + " synthesize an unconditioned, randomly invented speaker")
                        throw APIError(
                            status: .badRequest,
                            detail: "voice '\(resolved.slug)' has an empty reference transcript"
                                + " — \(backend.rawValue) cannot clone from it")
                    }
                    refPath = resolved.refURL.path
                    refText = resolved.meta.refText.isEmpty ? nil : resolved.meta.refText
                    trimSlug = resolved.slug
                } else if clones {
                    logError("/v1/audio/speech: \(StudioError.voiceNotFound(slug: voice))"
                        + " (model \(backend.rawValue)) — refusing to synthesize an"
                        + " unconditioned, randomly invented speaker")
                    throw APIError(status: .badRequest, detail: "voice '\(voice)' not found")
                }
            } else if clones {
                // No `voice` and no configured default: a cloning backend would
                // invent a speaker. Say so instead.
                logError("/v1/audio/speech: no voice given and no default voice is set"
                    + " (model \(backend.rawValue)) — refusing to synthesize an"
                    + " unconditioned, randomly invented speaker")
                throw APIError(status: .badRequest,
                               detail: "\(backend.rawValue) requires a 'voice'")
            }
            let knobEmotion = usedVariant ? Emotion.neutral
                : (req.emotion.flatMap(Emotion.init(rawValue:)) ?? .neutral)
            do {
                let result: SynthesisResult
                let synthRefPath = refPath, synthRefText = refText
                do {
                    // Same utility-priority hop as the chat route — see the
                    // note there and gloam-dj #297. Synthesis is the measured
                    // starver (a sustained generation stalled MusicKit
                    // mid-song on the gloam.fm shell).
                    result = try await Task(priority: GloamEngine.modelWorkPriority) {
                        try await deps.gate.run {
                            await deps.prepareTTS()
                            return try await deps.engine.synthesize(
                                backend: backend,
                                request: SynthesisRequest(
                                    text: req.input, refAudioPath: synthRefPath, refText: synthRefText,
                                    emotion: knobEmotion,
                                    speed: req.speed ?? 1.0,
                                    temperatureOverride: req.temperature,
                                    exaggerationOverride: req.exaggeration,
                                    exaggerationCeiling: req.exaggeration_ceiling,
                                    instruct: req.instruct, speaker: effectiveSpeaker,
                                    styleURL: styleURL, language: req.language,
                                    topP: req.top_p, topK: req.top_k, repetitionPenalty: req.repetition_penalty))
                        }
                    }.value
                } catch is RequestGate.Busy {
                    throw APIError(status: .serviceUnavailable, detail: "server busy — try again")
                }
                // The voice's own loudness trim. Applied HERE and not only in the
                // app, because this route is how everything off-machine hears a
                // voice — a trim that existed only in the Studio's own playback
                // would mean the voice sounds like itself in exactly one place.
                let trimmed = AudioAssembler.applyGain(
                    floats: result.samples,
                    db: trimSlug.map { deps.voices.gainDb(for: $0) } ?? 0)
                let wav = WAVEncoder.encode(pcm16: PCM16.data(from: trimmed),
                                            sampleRate: result.sampleRate)
                deps.log.record(.init(
                    method: "POST", path: "/v1/audio/speech", status: 200,
                    model: backend.rawValue, voice: req.voice, instruct: req.instruct,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000)))
                return Response(status: .ok,
                                headers: [.contentType: "audio/wav"],
                                body: .init(byteBuffer: ByteBuffer(data: wav)))
            } catch EngineError.licenseAckRequired(let b) {
                throw APIError(status: .forbidden, detail: licenseNotice(for: b))
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

        router.post("listen") { request, context in
            let req = try await request.decode(as: ListenRequest.self, context: context)
            do {
                let text = try await deps.gate.run {
                    try await deps.listen(req.maxSeconds ?? 30, req.silenceSeconds ?? 1.2, req.language)
                }
                return TranscriptResponse(text: text)
            } catch is RequestGate.Busy {
                throw APIError(status: .serviceUnavailable, detail: "server busy — try again")
            } catch {
                logError("listen failed: \(error)")
                throw APIError(status: .internalServerError, detail: "listen failed: \(error)")
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

/// Requires `Authorization: Bearer <token>` on every route except `/health`
/// when `authToken()` is non-nil (LAN mode). Loopback-only mode leaves
/// `authToken` at its `{ nil }` default, so nothing changes there. Full-string
/// `==` only — no prefix matching.
struct APIAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let authToken: @Sendable () -> String?
    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let token = authToken(), request.uri.path != "/health" else {
            return try await next(request, context)
        }
        guard let header = request.headers[.authorization],
              header == "Bearer \(token)" else {
            let body = try JSONEncoder().encode(["error": "unauthorized"])
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            headers[.contentLength] = String(body.count)
            return Response(status: .unauthorized, headers: headers,
                            body: .init(byteBuffer: ByteBuffer(data: body)))
        }
        return try await next(request, context)
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
