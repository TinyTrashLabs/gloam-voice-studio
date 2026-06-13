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

        router.post("v1/audio/speech") { request, context in
            let req = try await request.decode(as: SpeechRequest.self, context: context)
            if (req.response_format ?? "wav") != "wav" {
                throw APIError(status: .badRequest,
                               detail: "only response_format=wav is supported")
            }
            guard !req.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError(status: .badRequest, detail: "input is empty")
            }
            // OpenAI clients send voices like "alloy" — a matching library slug
            // clones that voice; unknown names fall through to no reference so
            // off-the-shelf clients work without config (server.py parity).
            let backend = req.model.flatMap(BackendID.init(rawValue:)) ?? deps.defaultBackend
            var refPath: String? = nil
            var refText: String? = nil
            if let voice = req.voice, let found = try? deps.voices.get(voice) {
                refPath = found.refURL.path
                refText = found.meta.refText.isEmpty ? nil : found.meta.refText
            }
            do {
                let result = try await deps.engine.synthesize(
                    backend: backend,
                    request: SynthesisRequest(text: req.input, refAudioPath: refPath,
                                              refText: refText))
                let wav = WAVEncoder.encode(pcm16: PCM16.data(from: result.samples),
                                            sampleRate: result.sampleRate)
                return Response(status: .ok,
                                headers: [.contentType: "audio/wav"],
                                body: .init(byteBuffer: ByteBuffer(data: wav)))
            } catch EngineError.licenseAckRequired {
                throw APIError(status: .forbidden, detail: fishLicenseNotice)
            } catch EngineError.refAudioRequired(let b) {
                throw APIError(status: .badRequest,
                               detail: "backend '\(b.rawValue)' requires reference audio")
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
