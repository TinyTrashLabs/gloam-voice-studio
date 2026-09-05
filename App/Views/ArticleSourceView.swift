import EngineKit
import StudioKit
import SwiftUI

/// The SOURCE zone of the Dialogue composer: a link, a topic search, or pasted
/// text becomes a two-host script.
///
/// Nothing here generates audio. It ends at a review sheet, because a script
/// nobody read is the one thing that cannot be fixed after the fact — once it
/// is finished audio, a wrong source or an invented statistic is invisible.
struct ArticleSourceView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool

    private var importer: ArticleImportModel { model.articleImport }

    var body: some View {
        @Bindable var importer = model.articleImport
        VStack(alignment: .leading, spacing: 10) {
            Picker("Source", selection: $importer.mode) {
                ForEach(ArticleImportModel.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("article-source-mode")

            switch importer.mode {
            case .link: linkInput($importer)
            case .topic: topicInput($importer)
            case .text: textInput($importer)
            }

            HStack(spacing: 10) {
                Picker("Length", selection: $importer.targetMinutes) {
                    Text("2 min").tag(2.0)
                    Text("5 min").tag(5.0)
                    Text("10 min").tag(10.0)
                }
                .frame(width: 150)
                .accessibilityIdentifier("article-length")
                .help("About how long the episode should be. It becomes a word budget — "
                      + "models hit word counts far more reliably than durations.")

                Button(scriptButtonTitle) { importer.scriptIt() }
                    .disabled(!importer.canScript)
                    .accessibilityIdentifier("article-script-it")
                if importer.phase.isBusy {
                    ProgressView().controlSize(.small)
                    Text(busyLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Brand.fgDim)
                    Button("Cancel") { importer.cancel() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Spacer()
            }

            if case .failed(let why) = importer.phase {
                Text(why)
                    .font(.callout).foregroundStyle(Brand.peak)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("article-error")
            }
            ForEach(importer.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if importer.mode == .topic, importer.phase == .hits || !importer.hits.isEmpty {
                hitList
            }
        }
        .sheet(isPresented: .init(get: { importer.phase == .review },
                                  set: { if !$0 { model.articleImport.discardReview() } })) {
            ArticleReviewSheet()
                .environment(model)
        }
    }

    private var scriptButtonTitle: String {
        importer.mode == .topic && importer.article == nil ? "Pick a result first" : "Script it"
    }

    private var busyLabel: String {
        switch importer.phase {
        case .searching: "Searching…"
        case .fetching: "Reading the page…"
        case .scripting: "Writing the script with \(model.chatLLM.rawValue)…"
        default: ""
        }
    }

    // MARK: - Inputs

    @ViewBuilder
    private func linkInput(_ importer: Bindable<ArticleImportModel>) -> some View {
        TextField("https://…", text: importer.link)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("article-link")
            .onSubmit { model.articleImport.scriptIt() }
        Text("The page is loaded and rendered here, then the article is pulled out of it. "
             + "Nothing leaves this Mac except the request for the page itself.")
            .font(.caption2).foregroundStyle(Brand.fgFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func topicInput(_ importer: Bindable<ArticleImportModel>) -> some View {
        HStack(spacing: 8) {
            TextField("What's it about?", text: importer.topic)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("article-topic")
                .onSubmit { model.articleImport.runSearch() }
            Button("Search") { model.articleImport.runSearch() }
                .disabled(importer.wrappedValue.topic.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("article-search")
        }
        Text("Results come from DuckDuckGo, with no account and no key. You pick which one "
             + "gets read — a bad source is invisible once it's finished audio.")
            .font(.caption2).foregroundStyle(Brand.fgFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func textInput(_ importer: Bindable<ArticleImportModel>) -> some View {
        TextEditor(text: importer.pastedText)
            .font(.body)
            .frame(minHeight: 90, maxHeight: 160)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.09), lineWidth: 1))
            .accessibilityIdentifier("article-text")
        Text("Paste the article body. This is the one that always works: paywalls, PDFs, "
             + "emails, and anything you wrote yourself.")
            .font(.caption2).foregroundStyle(Brand.fgFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Results

    @ViewBuilder
    private var hitList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(importer.hits) { hit in
                Button {
                    model.articleImport.choose(hit)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title).foregroundStyle(Brand.fg).font(.callout)
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet).font(.caption).foregroundStyle(Brand.fgDim)
                                .lineLimit(2)
                        }
                        Text(hit.url.host() ?? hit.url.absoluteString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Brand.fgFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(model.articleImport.article?.url == hit.url
                              ? Brand.accent.opacity(0.12) : Color.white.opacity(0.035)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("article-hit")
            }
        }
        .accessibilityIdentifier("article-hits")
    }
}

/// The approval gate. Editable, because the fastest fix for one bad line is to
/// retype it, not to regenerate the episode.
struct ArticleReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingRaw = false

    private var importer: ArticleImportModel { model.articleImport }

    var body: some View {
        @Bindable var importer = model.articleImport
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review the script").font(.title3.bold())
                Spacer()
                Text(String(format: "%d lines · about %.0fs",
                            importer.reviewLines.count, importer.reviewSeconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.fgDim)
            }
            if let article = importer.article {
                Text(article.title).font(.callout).foregroundStyle(Brand.fgDim)
                    .lineLimit(2)
            }
            ForEach(importer.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Brand.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($importer.reviewLines) { $line in
                        HStack(alignment: .top, spacing: 8) {
                            Picker("Speaker", selection: $line.speaker) {
                                Text("S1").tag(1)
                                Text("S2").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 80)
                            TextField("Line", text: $line.text, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...6)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.035)))
                            Button {
                                importer.reviewLines.removeAll { $0.id == line.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                            .accessibilityLabel("Remove line")
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            .accessibilityIdentifier("article-review-lines")

            DisclosureGroup("What the model actually said", isExpanded: $showingRaw) {
                ScrollView {
                    Text(importer.rawReply ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
            .font(.caption)

            HStack(spacing: 10) {
                Button("Cancel", role: .cancel) {
                    model.articleImport.discardReview()
                    dismiss()
                }
                Spacer()
                Button("Fill turns only") {
                    model.articleImport.applyToComposer()
                    dismiss()
                }
                .accessibilityIdentifier("article-fill-turns")
                Button("Use & Generate") {
                    model.articleImport.applyToComposer()
                    dismiss()
                    Task { await model.dialogue.generate() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("article-use-and-generate")
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }
}
