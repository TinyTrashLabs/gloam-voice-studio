import EngineKit
import StudioKit
import SwiftUI

/// Every take a voice carries, as a grid: one row per language it speaks (home first), one column
/// per style (Natural, Gloam's five, then any other style a take has). Filled cells play, show their
/// transcript and delete; empty cells offer the ways to add that take that actually work for that
/// language. Used by Edit Voice and by Create (the voice just saved).
struct VoiceTakesPanel: View {
    let slug: String
    /// Create mode: say these belong to the voice just saved.
    let note: Bool
    let player: PreviewPlayer
    @Binding var baker: BackendID
    /// The guided record-a-take flow (fixed English passage) for a home-language style.
    var onRecord: (Emotion) -> Void
    /// Asks before deleting the take at this address.
    var onDelete: (String) -> Void

    @Environment(AppModel.self) private var model
    @State private var adding: AddTakeTarget?
    @State private var openTranscript: String?

    private static let cellWidth: CGFloat = 86
    private static let rowLabelWidth: CGFloat = 110

    var body: some View {
        let _ = model.voicesVersion   // re-read after a take is baked / recorded / deleted
        let name = (try? model.voices.meta(slug).name) ?? slug
        let grid = model.voices.takeGrid(of: slug)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                zoneLabel("TAKES")
                Spacer()
                Picker("", selection: $baker) {
                    Text("fish-s2-pro").tag(BackendID.fishS2Pro)
                    Text("breeze-tts-2").tag(BackendID.breezeTTS2)
                    Text("chatterbox").tag(BackendID.chatterbox)
                }.labelsHidden().frame(width: 150)
                    .help("Generator for new takes. fish uses emotion markers (distinct emotions); breeze "
                        + "directs the clone with the expression in words (distinct emotions, needs the "
                        + "voice's transcript); chatterbox uses its exaggeration knob (intensity only — "
                        + "for users who can't run fish or breeze)")
            }
            (Text("Every take of  ").font(.callout).foregroundStyle(.secondary)
                + Text(name).font(.callout.weight(.bold)).foregroundStyle(Brand.accent)
                + Text("  · one row per language, one column per style")
                    .font(.caption2).foregroundStyle(Brand.fgFaint))
            Text("The whole app and API pick from these by the line's language and style."
                 + (note ? " (These belong to the voice you last saved.)" : ""))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let grid {
                // Scrolls sideways only when a voice has more styles than fit.
                ViewThatFits(in: .horizontal) {
                    gridView(grid)
                    ScrollView(.horizontal, showsIndicators: true) { gridView(grid) }
                }
                .accessibilityIdentifier("takes-grid")
                footer(grid, name: name)
            }
            if model.foundryBaking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Rendering take…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
        .sheet(item: $adding) { target in
            AddTakeSheet(baseSlug: slug, baseName: name, target: target,
                         homeLanguage: grid?.home,
                         existingLanguages: Set(grid?.rows.compactMap(\.language) ?? []), onSaved: {})
        }
    }

    // MARK: - Grid

    private func gridView(_ grid: VoiceTakeGrid) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: Self.rowLabelWidth, height: 1)
                ForEach(grid.columns, id: \.self) { column in
                    Text(column.title.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(column.isNatural ? Brand.fgDim : Brand.fgFaint)
                        .frame(width: Self.cellWidth, alignment: .center)
                        .help(columnHelp(column))
                }
            }
            ForEach(grid.rows, id: \.self) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.rowTitle(row)).font(.callout.weight(row.isHome ? .semibold : .regular))
                            .foregroundStyle(Brand.fg).lineLimit(1)
                        if let tag = row.language {
                            Text(tag).font(.system(size: 9, design: .monospaced)).foregroundStyle(Brand.fgFaint)
                        }
                    }
                    .frame(width: Self.rowLabelWidth, alignment: .leading)
                    ForEach(grid.columns, id: \.self) { column in
                        cell(grid, row: row, column: column)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func cell(_ grid: VoiceTakeGrid, row: VoiceTakeGrid.Row, column: VoiceTakeGrid.Column) -> some View {
        let takes = grid.takes(row, column)
        if takes.isEmpty {
            emptyCell(grid, row: row, column: column)
        } else {
            VStack(spacing: 4) {
                ForEach(takes, id: \.slug) { filledCell($0, row: row, english: Self.isEnglish(grid.home)) }
            }
        }
    }

    private func filledCell(_ take: VoiceTakeGrid.Take, row: VoiceTakeGrid.Row, english: Bool) -> some View {
        let url = (try? model.voices.get(take.slug))?.refURL
        let playing = player.playingID == take.slug
        return VStack(spacing: 5) {
            HStack(spacing: 4) {
                cellIcon(playing ? "stop.fill" : "play.fill", help: playing ? "Stop" : "Play this take") {
                    if let url { player.toggle(id: take.slug, url: url) }
                }
                .disabled(url == nil)
                .accessibilityIdentifier("take-play-\(take.key)")
                cellIcon("text.quote", help: "Transcript") {
                    openTranscript = openTranscript == take.slug ? nil : take.slug
                }
                .popover(isPresented: Binding(get: { openTranscript == take.slug },
                                              set: { if !$0 { openTranscript = nil } })) {
                    takeDetails(take, row: row, english: english)
                }
                .accessibilityIdentifier("take-transcript-\(take.key)")
                if !take.isDefault {
                    cellIcon("trash", help: "Delete this take") { onDelete(take.slug) }
                        .accessibilityIdentifier("take-delete-\(take.key)")
                }
            }
            HStack(spacing: 3) {
                if let mark = Self.originMark(take) {
                    Image(systemName: mark.icon).font(.system(size: 8)).help(mark.help)
                }
                Text(take.isDefault ? "default" : take.key)
                    .font(.system(size: 9, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(Brand.fgFaint)
        }
        .frame(width: Self.cellWidth, height: 52)
        .background(RoundedRectangle(cornerRadius: 7).fill(
            take.isDefault ? Brand.accent.opacity(0.10) : Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(
            take.isDefault ? Brand.accent.opacity(0.35) : Color.white.opacity(0.10), lineWidth: 1))
        .help(take.refText.isEmpty ? "No transcript" : "“\(take.refText)”")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("take-cell-\(take.key)")
    }

    /// The transcript and the actions that need more room than the cell: re-record / regenerate /
    /// replace.
    private func takeDetails(_ take: VoiceTakeGrid.Take, row: VoiceTakeGrid.Row, english: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Self.rowTitle(row)) · \(take.column.title)").font(.callout.weight(.semibold))
            Text(take.refText.isEmpty ? "No transcript." : "“\(take.refText)”")
                .font(.callout).foregroundStyle(take.refText.isEmpty ? Brand.fgFaint : Brand.fg)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Group {
                Text("Key: \(take.key)")
                if take.styleFromLegacyKey {
                    Text("Style read from its key (an older pack without a style field).")
                }
                if let mark = Self.originMark(take) { Text(mark.help) }
            }
            .font(.caption2).foregroundStyle(Brand.fgFaint)
            if !take.isDefault {
                HStack {
                    if row.isHome, english, let marker = VoiceExpression(rawValue: take.key) {
                        Button("Regenerate") {
                            openTranscript = nil
                            Task { await model.bakeExpressionVariants(
                                baseSlug: slug, expressions: [marker], baker: baker) }
                        }.disabled(model.foundryBaking)
                    }
                    if row.isHome, english, let emotion = Emotion(rawValue: take.key), emotion != .neutral {
                        Button("Re-record") { openTranscript = nil; onRecord(emotion) }
                    }
                    if let language = row.language, !row.isHome {
                        Button("Replace…") {
                            openTranscript = nil
                            adding = AddTakeTarget(language: language, style: Self.style(of: take.column))
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(14).frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private func emptyCell(_ grid: VoiceTakeGrid, row: VoiceTakeGrid.Row, column: VoiceTakeGrid.Column) -> some View {
        let english = Self.isEnglish(grid.home)
        let language = Self.languageName(row.language)
        VStack(spacing: 4) {
            if !column.isGloam && !column.isNatural {
                Text("—").foregroundStyle(Brand.fgFaint)
            } else if row.isHome, column.name == "neutral" {
                Text("—").foregroundStyle(Brand.fgFaint)
                    .help("Neutral renders from the Natural take, so a separate neutral take wouldn't be used here.")
            } else if row.isHome, english, let name = column.name, let emotion = Emotion(rawValue: name) {
                HStack(spacing: 4) {
                    cellIcon("mic.fill", help: "Record a \(name) take (guided English passage)") { onRecord(emotion) }
                        .accessibilityIdentifier("take-record-\(name)")
                    if let marker = VoiceExpression(rawValue: name) {
                        cellIcon("wand.and.stars", help: "Generate a \(name) take with \(baker.rawValue)") {
                            Task { await model.bakeExpressionVariants(
                                baseSlug: slug, expressions: [marker], baker: baker) }
                        }
                        .disabled(model.foundryBaking)
                        .accessibilityIdentifier("take-generate-\(name)")
                    }
                    cellIcon("plus", help: "Add a \(name) take from a clip and its transcript") {
                        adding = AddTakeTarget(language: nil, style: Self.style(of: column))
                    }
                }
            } else {
                cellIcon("plus", help: "Add a \(language) \(column.title.lowercased()) take: record or import "
                         + "a clip, with what it says in \(language)") {
                    adding = AddTakeTarget(language: row.isHome ? nil : row.language, style: Self.style(of: column))
                }
                .accessibilityIdentifier("take-add-\(row.language ?? "home")-\(column.name ?? "natural")")
                Text("no generator").font(.system(size: 8, design: .monospaced)).foregroundStyle(Brand.fgFaint)
                    .help("The generators read an English line, so they can't make a \(language) take yet — "
                          + "record or import one with its \(language) transcript.")
            }
        }
        .frame(width: Self.cellWidth, height: 52)
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    // MARK: - Below the grid

    @ViewBuilder
    private func footer(_ grid: VoiceTakeGrid, name: String) -> some View {
        HStack(spacing: 10) {
            Button { adding = AddTakeTarget(newLanguage: true) } label: {
                Label("Add a language…", systemImage: "globe")
            }
            .font(.caption).accessibilityIdentifier("takes-add-language")
            if grid.home == nil {
                Text("Set this voice's home language above so its own clip is labelled.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        // The rest of Fish's expressive vocabulary: generated in the home language (from an English
        // carrier line), shown as their own columns once they exist.
        let present = Set(grid.takes.map(\.key))
        let more = VoiceExpression.allCases.filter {
            !present.contains($0.rawValue) && !VoiceTakeGrid.gloamOrder.contains($0.rawValue)
        }
        if !more.isEmpty {
            if Self.isEnglish(grid.home) {
                Text("Generate another expression").font(.caption2).foregroundStyle(Brand.fgDim).padding(.top, 2)
                FlowLayout(spacing: 6) {
                    ForEach(more, id: \.self) { expr in addExpressionChip(expr) }
                }
            } else {
                Text("Generated expressions read an English line, so they aren't offered for a "
                     + "\(Self.languageName(grid.home)) voice.")
                    .font(.caption2).foregroundStyle(Brand.fgFaint)
            }
        }
    }

    private func addExpressionChip(_ expr: VoiceExpression) -> some View {
        Button {
            Task { await model.bakeExpressionVariants(baseSlug: slug, expressions: [expr], baker: baker) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                Text(expr.label).font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.04)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .foregroundStyle(Brand.fgDim)
        }
        .buttonStyle(.plain).disabled(model.foundryBaking)
        .accessibilityIdentifier("variant-add-\(expr.rawValue)")
    }

    // MARK: - Pieces

    private func cellIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain).foregroundStyle(Brand.fgDim)
        .help(help).accessibilityLabel(help)
    }

    private func zoneLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(2.0).foregroundStyle(Brand.fgFaint)
    }

    private func columnHelp(_ column: VoiceTakeGrid.Column) -> String {
        if column.isNatural { return "The voice's own delivery" }
        if column.isGloam { return "Gloam style “\(column.name ?? "")”" }
        if let vocabulary = column.vocabulary { return "Style “\(column.name ?? "")” from \(vocabulary)" }
        return "An acted expression, named by its key"
    }

    // MARK: - Labels

    static func languageName(_ tag: String?) -> String {
        guard let tag else { return "Unstated" }
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    static func rowTitle(_ row: VoiceTakeGrid.Row) -> String {
        guard row.isHome else { return languageName(row.language) }
        return row.language == nil ? "Home (unstated)" : "\(languageName(row.language)) (home)"
    }

    /// The recording passage and generator carrier line are English; an unstated home is treated as
    /// English, as the app always has.
    static func isEnglish(_ tag: String?) -> Bool {
        guard let tag else { return true }
        return tag == "en" || tag.hasPrefix("en-")
    }

    static func style(of column: VoiceTakeGrid.Column) -> VoiceStyle? {
        guard let name = column.name else { return nil }
        return column.isGloam ? VoiceStyle.gloam[name] : VoiceStyle(name: name, vocabulary: column.vocabulary)
    }

    private static func originMark(_ take: VoiceTakeGrid.Take) -> (icon: String, help: String)? {
        switch take.origin {
        case .generated?: return ("wand.and.stars", "Generated" + (take.engine.map { " with \($0)" } ?? ""))
        case .recorded?: return ("mic.fill", "Recorded here")
        case .imported?: return ("square.and.arrow.down", "Imported from a clip")
        case nil: return nil
        }
    }
}

/// What "add a take" is for.
struct AddTakeTarget: Identifiable {
    /// A language the voice doesn't speak yet: its natural take, language picked in the sheet.
    var newLanguage = false
    /// The take's language; nil = the home language.
    var language: String?
    /// Nil = natural delivery.
    var style: VoiceStyle?
    var id: String { newLanguage ? "new-language" : "\(language ?? "home")-\(style?.name ?? "natural")" }
}
