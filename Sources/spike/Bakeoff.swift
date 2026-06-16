import EngineKit
import Foundation

// MARK: - Bakeoff harness
//
// `spike bakeoff [outPath] [--dry]` — loads each local LLM in turn and scores
// how well it produces the DJ "pick" JSON under three contract sizes across five
// room scenarios (4 models × 3 variants × 5 scenarios = 60 cells). One resident
// model at a time; GloamEngine evicts+reloads as the backend changes, so a single
// engine iterates the whole matrix sequentially.
//
// This file owns ALL the bake-off data (variants, scenarios, prompt builder, JSON
// scorer, markdown writer). main.swift just dispatches into Bakeoff.run.

public enum Bakeoff {

    // MARK: Voices

    /// Neutral, broadly crowd-pleasing selection voice (mirrors NEUTRAL_SELECTION_PROMPT).
    static let neutralVoice =
        "You are a versatile, professional party DJ with broad, crowd-pleasing taste."
    /// Cruz's deep/tech-house voice.
    static let houseVoice =
        "You are Cruz, a deep/tech-house DJ. Your sets are hypnotic, groove-first, "
        + "late-night warehouse energy: rolling basslines, minimal vocals, peak-time drive."

    // MARK: Contract variants

    /// A required field for scoring a returned pick.
    enum RequiredField: String {
        case title, artist, energy, mood, reason
    }

    /// One JSON contract size: the schema instruction appended to the system prompt
    /// plus which fields each pick must carry to count as "fieldsOK".
    struct Variant {
        let id: String
        let schemaInstruction: String
        let required: [RequiredField]
    }

    static let strictTail =
        "Use real song titles + real artist names — no fabrications. "
        + "STRICT JSON only, no prose, no markdown."

    static let variants: [Variant] = [
        Variant(
            id: "v1_full",
            schemaInstruction: [
                "Return 3 ranked picks (1 = best fit). \(strictTail)",
                "{",
                "  \"picks\": [",
                "    { \"title\": \"<exact song title>\", \"artist\": \"<artist name>\", "
                    + "\"energy\": <0..1>, \"mood\": \"<one or two words>\", "
                    + "\"reason\": \"<one short DJ-style sentence>\" },",
                "    ...",
                "  ]",
                "}",
            ].joined(separator: "\n"),
            required: [.title, .artist, .energy, .mood, .reason]),
        Variant(
            id: "v2_trim",
            schemaInstruction: [
                "Return 3 ranked picks (1 = best fit). \(strictTail)",
                "{",
                "  \"picks\": [",
                "    { \"title\": \"<exact song title>\", \"artist\": \"<artist name>\", "
                    + "\"energy\": <0..1> },",
                "    ...",
                "  ]",
                "}",
            ].joined(separator: "\n"),
            required: [.title, .artist, .energy]),
        Variant(
            id: "v3_minimal",
            schemaInstruction: [
                "Return the single best pick. \(strictTail)",
                "{",
                "  \"picks\": [",
                "    { \"title\": \"<exact song title>\", \"artist\": \"<artist name>\" }",
                "  ]",
                "}",
            ].joined(separator: "\n"),
            required: [.title, .artist]),
    ]

    // MARK: Scenarios

    struct Track {
        let title: String
        let artist: String
    }

    /// A room snapshot to prompt the model with.
    struct Scenario {
        let label: String
        let voice: String
        let phase: String
        let energy: Double
        let arc: String?
        let brief: String?
        let current: Track?
        let recentSkips: [Track]
    }

    static let scenarios: [Scenario] = [
        Scenario(
            label: "arrivals-low-neutral",
            voice: neutralVoice,
            phase: "arrivals",
            energy: 0.2,
            arc: nil,
            brief: nil,
            current: Track(title: "Teardrop", artist: "Massive Attack"),
            recentSkips: []),
        Scenario(
            label: "peak-high-house",
            voice: houseVoice,
            phase: "peak",
            energy: 0.9,
            arc: "peak",
            brief: nil,
            current: Track(title: "You & Me - Flume Remix", artist: "Disclosure"),
            recentSkips: []),
        Scenario(
            label: "comedown-mid-neutral",
            voice: neutralVoice,
            phase: "comedown",
            energy: 0.4,
            arc: "descending",
            brief: nil,
            current: Track(title: "Midnight City", artist: "M83"),
            recentSkips: []),
        Scenario(
            label: "peak-brief-hiphop",
            voice: neutralVoice,
            phase: "peak",
            energy: 0.85,
            arc: nil,
            brief: "90s hip-hop birthday party for Marcus",
            current: Track(title: "Juicy", artist: "The Notorious B.I.G."),
            recentSkips: []),
        Scenario(
            label: "warmup-skips",
            voice: neutralVoice,
            phase: "warmup",
            energy: 0.6,
            arc: nil,
            brief: nil,
            current: Track(title: "Get Lucky", artist: "Daft Punk"),
            recentSkips: [
                Track(title: "Sandstorm", artist: "Darude"),
                Track(title: "Macarena", artist: "Los del Río"),
            ]),
    ]

    // MARK: Prompt builder
    //
    // Mirrors the production proposal prompt in web/src/brain/LibrarySelector.ts.

    static func buildRequest(variant: Variant, scenario: Scenario) -> ChatRequest {
        var systemParts: [String] = [scenario.voice, ""]
        if let brief = scenario.brief {
            systemParts.append(
                "THE BRIEF FOR THIS SET — top priority, every pick must serve it:\n\"\(brief)\"")
        }
        systemParts.append(
            "You are picking the NEXT TRACK like a real DJ working a room. You can suggest "
            + "ANY song that exists — pull from your full knowledge of music, not just what's "
            + "nearby. Pick songs that genuinely fit.")
        systemParts.append(
            "Phase: \(scenario.phase). Room energy: \(String(format: "%.2f", scenario.energy)) "
            + "(0=dead, 1=peak).")
        if let arc = scenario.arc {
            systemParts.append("Arc: we are on the \(arc) side of the night.")
        }
        systemParts.append("")
        systemParts.append(variant.schemaInstruction)
        let system = systemParts.joined(separator: "\n")

        var userParts: [String] = []
        if let current = scenario.current {
            userParts.append("Currently playing: \(current.title) — \(current.artist)")
        }
        if !scenario.recentSkips.isEmpty {
            let lines = scenario.recentSkips
                .map { "  - \($0.title) — \($0.artist)" }
                .joined(separator: "\n")
            userParts.append("The crowd just SKIPPED these — steer AWAY:\n\(lines)")
        }
        userParts.append("(seed: \(randomSeed()) · \(Int.random(in: 0..<100_000)))")
        let user = userParts.joined(separator: "\n")

        return ChatRequest(
            messages: [
                .init(role: .system, content: system),
                .init(role: .user, content: user),
            ],
            temperature: 0.95,
            maxTokens: 600,
            disableThinking: true)
    }

    /// 6 random alphanumerics, matching the JS `Math.random().toString(36).slice(2,8)` seed feel.
    static func randomSeed() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: JSON scorer
    //
    // Ports extractJsonObject from web/src/brain/jsonExtract.ts.

    /// Strip code-fence wrapping, slice from the first `{` to the last `}`, JSONSerialize.
    /// Returns the parsed object or nil.
    static func extractJsonObject(_ raw: String) -> [String: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading ``` or ```json fence (case-insensitive).
        if let fence = leadingFenceRange(text) {
            text = String(text[fence.upperBound...])
        }
        // Strip a trailing ``` fence.
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// Matches `^```(json)?\s*` case-insensitively at the head of `text`.
    private static func leadingFenceRange(_ text: String) -> Range<String.Index>? {
        guard text.hasPrefix("```") else { return nil }
        var idx = text.index(text.startIndex, offsetBy: 3)
        let lower = text.lowercased()
        if lower[idx...].hasPrefix("json") {
            idx = text.index(idx, offsetBy: 4)
        }
        // Consume trailing whitespace of the fence line.
        while idx < text.endIndex, text[idx] == " " || text[idx] == "\t" || text[idx] == "\n"
            || text[idx] == "\r" {
            idx = text.index(after: idx)
        }
        return text.startIndex..<idx
    }

    /// Scoring outcome for one cell.
    struct CellScore {
        var validJSON: Bool
        var fieldsOK: Bool
        var pickCount: Int
        var thinkLeak: Bool
    }

    static func score(text: String, variant: Variant) -> CellScore {
        let thinkLeak = text.lowercased().contains("<think>")
        guard let parsed = extractJsonObject(text),
              let picks = parsed["picks"] as? [Any], !picks.isEmpty else {
            return CellScore(validJSON: false, fieldsOK: false, pickCount: 0, thinkLeak: thinkLeak)
        }
        let pickCount = picks.count
        var fieldsOK = true
        for pickAny in picks {
            guard let pick = pickAny as? [String: Any] else { fieldsOK = false; break }
            if !pickHasRequiredFields(pick, required: variant.required) {
                fieldsOK = false
                break
            }
        }
        return CellScore(validJSON: true, fieldsOK: fieldsOK, pickCount: pickCount,
                         thinkLeak: thinkLeak)
    }

    private static func pickHasRequiredFields(_ pick: [String: Any],
                                              required: [RequiredField]) -> Bool {
        for field in required {
            switch field {
            case .title, .artist, .mood, .reason:
                guard let s = pick[field.rawValue] as? String,
                      !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
            case .energy:
                guard let n = numberValue(pick["energy"]), n >= 0, n <= 1 else { return false }
            }
        }
        return true
    }

    /// Coerce a JSON value to a Double if it is a number (NSNumber / Double / Int).
    private static func numberValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Result record

    struct CellResult {
        let model: LLMBackendID
        let variant: Variant
        let scenario: Scenario
        let rawText: String
        let score: CellScore
        let latencySeconds: Double
        let completionTokens: Int
        let error: String?
    }

    // MARK: Metallib auto-provision
    //
    // mlx-swift's Metal library isn't bundled next to a SwiftPM CLI binary, so MLX
    // fails to load with "Failed to load the default metallib". We copy
    // mlx-swift_Cmlx.bundle next to the executable from the nearest known build
    // location before loading any model.

    static func ensureMetallib() {
        let fm = FileManager.default
        let execDir: URL = {
            if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
                return exe
            }
            return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        }()
        let dest = execDir.appendingPathComponent("mlx-swift_Cmlx.bundle")
        if fm.fileExists(atPath: dest.path) {
            print("metallib: already present at \(dest.path)")
            return
        }

        let repoRoot = findRepoRoot(from: execDir)
        var candidates: [URL] = []
        candidates.append(contentsOf: derivedDataMetallibs())
        if let repoRoot {
            candidates.append(repoRoot
                .appendingPathComponent("build-app/Build/Products/Debug/mlx-swift_Cmlx.bundle"))
            candidates.append(repoRoot
                .appendingPathComponent("build/Build/Products/Release/mlx-swift_Cmlx.bundle"))
        }

        for src in candidates where fm.fileExists(atPath: src.path) {
            do {
                try fm.copyItem(at: src, to: dest)
                print("metallib: copied \(src.path) → \(dest.path)")
                return
            } catch {
                print("metallib: failed copying \(src.path): \(error)")
            }
        }

        print("WARNING: mlx-swift_Cmlx.bundle not found in any known build location. "
            + "Model loading will fail with 'Failed to load the default metallib'. "
            + "Build the Xcode app once (or `swift build`) to produce the bundle, then re-run.")
    }

    /// Glob `~/Library/Developer/Xcode/DerivedData/GloamVoiceStudio-*/Build/Products/Debug/`
    /// for the mlx bundle.
    private static func derivedDataMetallibs() -> [URL] {
        let fm = FileManager.default
        let derived = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        guard let entries = try? fm.contentsOfDirectory(
            at: derived, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [URL] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("GloamVoiceStudio-") {
            out.append(entry
                .appendingPathComponent("Build/Products/Debug/mlx-swift_Cmlx.bundle"))
        }
        return out
    }

    /// Walk up from `start` looking for a directory containing Package.swift.
    private static func findRepoRoot(from start: URL) -> URL? {
        let fm = FileManager.default
        var dir = start
        for _ in 0..<12 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: Model directory resolution

    static func modelDir(for backend: LLMBackendID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models")
            .appendingPathComponent(backend.diskFolder)
    }

    // MARK: Entry point

    public static func run(models: [LLMBackendID], outPath: String, dryRun: Bool) async {
        let plannedCells = models.count * variants.count * scenarios.count

        if dryRun {
            print("=== bakeoff DRY RUN — nothing will be downloaded or loaded ===")
            print("models:    \(models.count)  (\(models.map(\.rawValue).joined(separator: ", ")))")
            print("variants:  \(variants.count)  (\(variants.map(\.id).joined(separator: ", ")))")
            print("scenarios: \(scenarios.count)  "
                + "(\(scenarios.map(\.label).joined(separator: ", ")))")
            print("planned cells: \(models.count) × \(variants.count) × \(scenarios.count) "
                + "= \(plannedCells)")
            print("outPath:   \(outPath)")
            print("")
            print("resolved model dirs:")
            for m in models {
                let dir = modelDir(for: m)
                let present = FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("config.json").path)
                print("  \(m.rawValue)  [\(m.repoId)]")
                print("    -> \(dir.path)  (config.json \(present ? "present" : "MISSING"))")
            }
            print("")
            print("cell plan (model | variant | scenario):")
            for m in models {
                for v in variants {
                    for s in scenarios {
                        print("  \(m.rawValue) | \(v.id) | \(s.label)")
                    }
                }
            }
            print("")
            print("dry run complete — \(plannedCells) cells planned, 0 models loaded.")
            return
        }

        ensureMetallib()

        let engine = GloamEngine(
            provider: MLXModelProvider(),
            languageProvider: MLXLanguageModelProvider(
                modelDirectoryResolver: { modelDir(for: $0) }))

        var results: [CellResult] = []

        for model in models {
            // Ensure the model is downloaded before loading.
            let dir = modelDir(for: model)
            let configPresent = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("config.json").path)
            let weightsPresent = ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? [])
                .contains { $0.pathExtension == "safetensors" }
            if !configPresent || !weightsPresent {
                print("downloading \(model.repoId) → \(dir.path)")
                let tracker = PctTracker()
                do {
                    try await downloadHFSnapshot(repo: model.repoId, to: dir) { p in
                        if let pct = tracker.step(p) { print("  \(pct)%") }
                    }
                    print("download complete: \(model.rawValue)")
                } catch {
                    print("ERROR downloading \(model.rawValue): \(error) — skipping model")
                    // Record failed cells so the report shows the gap.
                    for v in variants {
                        for s in scenarios {
                            results.append(CellResult(
                                model: model, variant: v, scenario: s, rawText: "",
                                score: CellScore(validJSON: false, fieldsOK: false,
                                                 pickCount: 0, thinkLeak: false),
                                latencySeconds: 0, completionTokens: 0,
                                error: "download failed: \(error)"))
                        }
                    }
                    continue
                }
            }

            for v in variants {
                for s in scenarios {
                    let request = buildRequest(variant: v, scenario: s)
                    do {
                        let result = try await engine.chat(backend: model, request: request)
                        let cellScore = score(text: result.text, variant: v)
                        results.append(CellResult(
                            model: model, variant: v, scenario: s, rawText: result.text,
                            score: cellScore, latencySeconds: result.wallSeconds,
                            completionTokens: result.usage.completionTokens, error: nil))
                        print(String(format: "%@ | %@ | %@ -> validJSON=%@ %.2fs",
                                     model.rawValue, v.id, s.label,
                                     cellScore.validJSON ? "true" : "false",
                                     result.wallSeconds))
                    } catch {
                        results.append(CellResult(
                            model: model, variant: v, scenario: s, rawText: "",
                            score: CellScore(validJSON: false, fieldsOK: false,
                                             pickCount: 0, thinkLeak: false),
                            latencySeconds: 0, completionTokens: 0, error: "\(error)"))
                        print("\(model.rawValue) | \(v.id) | \(s.label) -> ERROR: \(error)")
                    }
                }
            }
        }

        let markdown = renderMarkdown(models: models, results: results)
        do {
            try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
            print("wrote \(results.count) cells -> \(outPath)")
        } catch {
            print("ERROR writing \(outPath): \(error)")
        }
        print(outPath)
    }

    // MARK: Markdown writer

    static func renderMarkdown(models: [LLMBackendID], results: [CellResult]) -> String {
        var lines: [String] = []
        lines.append("# DJ pick-JSON bake-off")
        lines.append("")
        let fmt = ISO8601DateFormatter()
        lines.append("Generated \(fmt.string(from: Date())) · "
            + "\(models.count) models × \(variants.count) variants × \(scenarios.count) scenarios "
            + "= \(results.count) cells.")
        lines.append("")

        // Summary table: one row per (model, variant), aggregated across scenarios.
        lines.append("## Summary")
        lines.append("")
        lines.append("| model | variant | valid% | fieldsOK% | avgLatencyS | avgOutTokens | "
            + "thinkLeaks |")
        lines.append("|---|---|---:|---:|---:|---:|---:|")
        for m in models {
            for v in variants {
                let cells = results.filter { $0.model == m && $0.variant.id == v.id }
                let n = max(cells.count, 1)
                let validPct = Double(cells.filter { $0.score.validJSON }.count) / Double(n) * 100
                let fieldsPct = Double(cells.filter { $0.score.fieldsOK }.count) / Double(n) * 100
                let avgLatency = cells.map(\.latencySeconds).reduce(0, +) / Double(n)
                let avgTokens = Double(cells.map(\.completionTokens).reduce(0, +)) / Double(n)
                let thinkLeaks = cells.filter { $0.score.thinkLeak }.count
                lines.append(String(
                    format: "| %@ | %@ | %.0f%% | %.0f%% | %.2f | %.0f | %d |",
                    m.rawValue, v.id, validPct, fieldsPct, avgLatency, avgTokens, thinkLeaks))
            }
        }
        lines.append("")

        // Details: model -> variant -> scenario, with raw output.
        lines.append("## Details")
        lines.append("")
        for m in models {
            lines.append("### \(m.rawValue)  (`\(m.repoId)`)")
            lines.append("")
            for v in variants {
                lines.append("#### \(v.id)")
                lines.append("")
                for s in scenarios {
                    guard let cell = results.first(where: {
                        $0.model == m && $0.variant.id == v.id && $0.scenario.label == s.label
                    }) else { continue }
                    lines.append("- **\(s.label)** — "
                        + "latency \(String(format: "%.2f", cell.latencySeconds))s · "
                        + "picks \(cell.score.pickCount) · "
                        + "validJSON \(cell.score.validJSON) · "
                        + "fieldsOK \(cell.score.fieldsOK)"
                        + (cell.error.map { " · error: \($0)" } ?? ""))
                    lines.append("")
                    lines.append("```")
                    lines.append(cell.error == nil ? cell.rawText : "<\(cell.error!)>")
                    lines.append("```")
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
