import EngineKit
import StudioKit
import SwiftUI
import UniformTypeIdentifiers

/// Chat tab: conversations with the sidebar-selected voice. Layout mirrors
/// LM Studio: conversation list | transcript + composer | inspector.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var imageImporterPresented = false
    @State private var renamingConversation: Conversation?
    @State private var renameDraft = ""
    @State private var pendingDeleteConversation: Conversation?
    /// Owned here (not by the DictationButton) so send can cancel an open mic:
    /// sending mid-dictation must close capture — the echo guard would mute
    /// the reply — and orphan the session so a late Whisper final can't write
    /// the already-sent text back into the cleared draft.
    @State private var dictation = DictationController()
    @State private var exportDoc: DataDocument?

    /// Pin the transcript to its end on the NEXT runloop pass, after layout
    /// has absorbed whatever change triggered this.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("chat-bottom", anchor: .bottom)
        }
    }

    /// Send path shared by ⏎ and the send button.
    private func sendFromComposer() {
        if dictation.isActive || dictation.isProcessing {
            dictation.cancel()
            model.chat.setMicCapture(false)
        }
        model.chat.send()
    }

    var body: some View {
        @Bindable var chat = model.chat
        Group {
            if let slug = model.selectedVoiceSlug, let meta = try? model.voices.get(slug).meta {
                HStack(spacing: 0) {
                    conversationColumn
                        .frame(width: 190)
                        .background(Brand.ink2.opacity(0.5))
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                    transcriptColumn(voice: meta)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                    ChatInspectorView()
                        .frame(width: 280)
                        .background(Brand.ink2.opacity(0.5))
                }
            } else {
                emptyState
            }
        }
        .task(id: model.selectedVoiceSlug) { model.chat.refresh() }
        .onChange(of: model.selectedVoiceSlug) { model.chat.stop() }
        .fileExporter(isPresented: .init(get: { exportDoc != nil },
                                         set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .wav,
                      defaultFilename: "gloam-chat-take") { _ in exportDoc = nil }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34)).foregroundStyle(Brand.fgFaint)
            Text("Pick a voice in the sidebar to start chatting.")
                .foregroundStyle(Brand.fgDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: conversation list

    private var conversationColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CHATS").font(.system(size: 11, weight: .heavy)).tracking(1)
                    .foregroundStyle(Brand.fgDim)
                Spacer()
                Button { model.chat.newConversation() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(Brand.fgDim)
                .accessibilityIdentifier("chat-new-conversation")
                .help("New chat")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.chat.conversations) { convo in
                        conversationRow(convo)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .alert("Rename Chat",
               isPresented: Binding(get: { renamingConversation != nil },
                                    set: { if !$0 { renamingConversation = nil } }),
               presenting: renamingConversation) { convo in
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                model.chat.renameConversation(convo, to: renameDraft)
                renamingConversation = nil
            }
            Button("Cancel", role: .cancel) { renamingConversation = nil }
        } message: { _ in
            Text("Give this chat a new title.")
        }
        .confirmationDialog(
            "Delete “\(pendingDeleteConversation?.title ?? "")”?",
            isPresented: Binding(get: { pendingDeleteConversation != nil },
                                 set: { if !$0 { pendingDeleteConversation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let convo = pendingDeleteConversation {
                    model.chat.deleteConversation(convo)
                }
                pendingDeleteConversation = nil
            }
            .accessibilityIdentifier("confirm-delete-conversation")
        } message: {
            Text("The conversation and any saved reply audio move to the Trash.")
        }
    }

    private func conversationRow(_ convo: Conversation) -> some View {
        Button { model.chat.select(convo) } label: {
            Text(convo.title)
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(convo.id == model.chat.current?.id ? Brand.fg : Brand.fgDim)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(convo.id == model.chat.current?.id
                          ? Color.white.opacity(0.07) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                renameDraft = convo.title
                renamingConversation = convo
            }
            Button("Delete", role: .destructive) { pendingDeleteConversation = convo }
        }
    }

    // MARK: transcript + composer

    private func transcriptColumn(voice: VoiceMeta) -> some View {
        @Bindable var chat = model.chat
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack, deliberately: scrollTo can't reach a
                    // LazyVStack row that hasn't materialized, which made the
                    // bottom pin work only "sometimes". Conversations are
                    // bounded, so eager layout is fine.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.current?.messages ?? []) { message in
                            bubble(message, voice: voice)
                        }
                        if chat.isStreaming {
                            bubble(ChatMessage(id: "streaming", role: "assistant",
                                               text: chat.streamingText,
                                               createdAt: ""),
                                   voice: voice, isStreamingBubble: true)
                                .id("streaming-bubble")
                        }
                        if let error = chat.chatError {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.red)
                                Button("Retry") { model.chat.retry() }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityIdentifier("chat-retry")
                            }
                        }
                        if let warning = chat.speechWarning {
                            Label(warning, systemImage: "speaker.slash")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Start at the bottom on conversation switch…
                .defaultScrollAnchor(.bottom)
                // …and stay pinned while a reply streams in — the passive
                // anchor alone loses its pin once the streaming bubble starts
                // growing, so reinforce it on every delta and new message.
                // The scroll is deferred out of the layout transaction: a
                // scrollTo issued in the same pass as the content change
                // targets the OLD geometry and lands short.
                .onChange(of: chat.streamingText) { scrollToBottom(proxy) }
                .onChange(of: chat.current?.messages.count) { scrollToBottom(proxy) }
                .onChange(of: chat.current?.id) { scrollToBottom(proxy) }
                .onChange(of: chat.chatError) { scrollToBottom(proxy) }
                .onAppear { scrollToBottom(proxy) }
            }
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if let pending = chat.pendingImage {
                HStack(spacing: 8) {
                    if let img = NSImage(contentsOf: pending) {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: 44, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(pending.lastPathComponent)
                        .font(.caption2).foregroundStyle(Brand.fgDim).lineLimit(1)
                    Button { model.chat.pendingImage = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.fgFaint)
                    }
                    .buttonStyle(.plain)
                    .help("Remove attachment")
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            composer
        }
    }

    private func bubble(_ message: ChatMessage, voice: VoiceMeta, isStreamingBubble: Bool = false) -> some View {
        // The last real (non-streaming) assistant message is the one whose replay
        // icon should mirror "now speaking" — the streaming bubble has no replay
        // button of its own.
        let isLastAssistantMessage = !isStreamingBubble
            && model.chat.current?.messages.last(where: { $0.role == "assistant" })?.id == message.id
        let isSpeakingThis = isLastAssistantMessage && model.chat.speech.isSpeaking
        return HStack(alignment: .top, spacing: 10) {
            if message.role == "assistant" {
                VoiceAvatarView(slug: voice.slug, name: voice.name,
                                avatarURL: model.voices.avatarURL(voice.slug), size: 26)
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(Brand.fgFaint)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(message.role == "assistant" ? voice.name : "You")
                        .font(.caption.bold()).foregroundStyle(Brand.fgDim)
                    if message.errored == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                            .help("Reply was interrupted")
                    }
                    // Dancing dots while tokens are actively flowing into this
                    // bubble — livelier than a spinner, and it reads as "the
                    // model is talking".
                    if isStreamingBubble, model.chat.isStreaming, !message.text.isEmpty {
                        BouncingDots(color: Brand.fgFaint)
                    }
                    if message.role == "assistant", !isStreamingBubble {
                        let isPending = model.chat.pendingAudioMessageIDs.contains(message.id)
                        Button { model.chat.speak(message) } label: {
                            if isPending {
                                ProgressView().controlSize(.mini)
                            } else if isSpeakingThis {
                                // Same EQ motif the sidebar uses for a playing
                                // sample — "this voice is speaking now".
                                EqualizerBars()
                            } else {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isPending)
                        .foregroundStyle(isSpeakingThis ? Brand.accent : Brand.fgFaint)
                        .help(isPending ? "Synthesizing…"
                              : (isSpeakingThis ? "Speaking…" : "Speak this reply"))
                        .accessibilityIdentifier("chat-speak")
                        Menu {
                            chatAudioMenu(for: message)
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .foregroundStyle(Brand.fgFaint)
                        .help("Takes, regenerate, export")
                        .accessibilityIdentifier("chat-audio-menu")
                    }
                }
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { path in
                            if let img = NSImage(contentsOfFile: path) {
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: 140, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                if isStreamingBubble, message.text.isEmpty {
                    // Nothing has streamed back yet — first-send model load can
                    // take 10+ seconds, or much longer if the model needs to
                    // download first (ChatController now auto-downloads rather
                    // than dead-ending) — show real progress in that case so a
                    // multi-minute download doesn't look like a hang.
                    HStack(spacing: 6) {
                        BouncingDots(color: Brand.fgDim)
                        if case .downloading(let fraction) = model.downloads.state(for: model.chatLLM) {
                            Text("Downloading… \(Int(fraction * 100))%")
                                .font(.caption).foregroundStyle(Brand.fgDim)
                        } else {
                            Text("Thinking…").font(.caption).foregroundStyle(Brand.fgDim)
                        }
                    }
                    .accessibilityIdentifier("chat-thinking")
                } else if message.role == "assistant" {
                    let parts = splitThinking(message.text)
                    if let thinking = parts.thinking {
                        // Reasoning renders collapsed, LM Studio-style — not as
                        // raw <think> tags in the reply.
                        ThinkingDisclosure(
                            text: thinking,
                            isLive: isStreamingBubble && parts.answer.isEmpty)
                    }
                    if model.chat.speech.isSpeaking {
                        // Karaoke: follow the voice through the transcript.
                        SpokenTextView(text: parts.answer, queue: model.chat.speech)
                    } else if !parts.answer.isEmpty {
                        Text(parts.answer)
                            .textSelection(.enabled)
                            .foregroundStyle(Brand.fg)
                    }
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                        .foregroundStyle(Brand.fg)
                }
            }
            Spacer(minLength: 40)
        }
        .accessibilityIdentifier("chat-message-\(message.role)")
    }

    @ViewBuilder
    private func chatAudioMenu(for message: ChatMessage) -> some View {
        let takes = (message.audioTakeIDs ?? []).compactMap { model.chatAudioStore.entry($0) }
        if !takes.isEmpty {
            Section("Takes") {
                ForEach(takes, id: \.id) { entry in
                    Button {
                        model.chat.setCurrentTake(entry.id, for: message)
                    } label: {
                        if entry.id == message.currentTakeID {
                            Label(entry.backend, systemImage: "checkmark")
                        } else {
                            Text(entry.backend)
                        }
                    }
                }
            }
            Divider()
        }
        Menu("Regenerate with…") {
            ForEach(BackendID.allCases, id: \.self) { backend in
                let ramOK = model.hasSufficientRAM(for: backend)
                Button(ramOK ? backend.rawValue
                       : "\(backend.rawValue) (\(model.ramRequirementLabel(minRAMBytes: backend.spec.minRAMBytes)))") {
                    Task { await model.chat.regenerateAudio(for: message, backend: backend) }
                }
                .disabled(!ramOK)
            }
        }
        if message.currentTakeID != nil {
            Button("Export…") { exportCurrentTake(message) }
        }
    }

    private func exportCurrentTake(_ message: ChatMessage) {
        guard let takeID = message.currentTakeID,
              let url = try? model.chatAudioStore.wavURL(takeID),
              let data = try? Data(contentsOf: url),
              let entry = model.chatAudioStore.entry(takeID)
        else { return }
        // Re-encode with the provenance tag for files leaving the app —
        // mirrors Studio's Export (StudioView.swift).
        let pcm = data.dropFirst(44)
        exportDoc = DataDocument(data: WAVEncoder.encode(
            pcm16: Data(pcm), sampleRate: entry.sampleRate,
            provenance: WAVEncoder.provenanceComment))
    }

    private var composer: some View {
        @Bindable var chat = model.chat
        return HStack(alignment: .bottom, spacing: 10) {
            // Push-to-talk: dictate into the draft, then send as usual.
            // (Whisper emits its text after the mic stops — the button shows
            // its own transcribing spinner meanwhile.) While the mic is open,
            // speech output is silenced so the reply can't dictate itself.
            DictationButton(text: $chat.draft,
                            onActiveChange: { model.chat.setMicCapture($0) },
                            externalController: dictation)
                .padding(.bottom, 10)
            // Vision models can see: attach an image to ride with the next send.
            if model.chatLLM.supportsVision {
                Button { imageImporterPresented = true } label: {
                    Image(systemName: "photo.badge.plus")
                        .foregroundStyle(chat.pendingImage != nil ? Brand.accent : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 11)
                .accessibilityIdentifier("chat-attach-image")
                .help("Attach an image for the model to look at")
                .fileImporter(isPresented: $imageImporterPresented,
                              allowedContentTypes: [.png, .jpeg, .heic, .image]) { result in
                    if case .success(let url) = result { model.chat.attachImage(from: url) }
                }
            }
            TextField("Message \(voiceName())…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .accessibilityIdentifier("chat-composer")
                .onSubmit { sendFromComposer() }
            if chat.isStreaming || chat.speech.isSpeaking || chat.isSynthesizing {
                // Busy cue alongside the stop control: EQ bars while the voice
                // model renders or audio plays, dancing dots while the LLM
                // generates. Both can be true (speak-while-generating) — audio
                // wins, it's the more tangible activity.
                Group {
                    if chat.speech.isSpeaking || chat.isSynthesizing {
                        EqualizerBars()
                    } else {
                        BouncingDots(color: Brand.fgDim)
                    }
                }
                .accessibilityIdentifier("chat-activity")
                .padding(.bottom, 12)
                Button { model.chat.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .padding(.bottom, 11)
                .accessibilityIdentifier("chat-stop")
                .help("Stop generating / speaking")
            } else {
                Button { sendFromComposer() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? Brand.fgFaint : Brand.accent)
                .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 9)
                .accessibilityIdentifier("chat-send")
                .keyboardShortcut(.return, modifiers: [])
                .help("Send (⏎)")
            }
        }
        .padding(12)
    }

    private func voiceName() -> String {
        model.selectedVoiceSlug.flatMap { try? model.voices.get($0).meta.name } ?? "voice"
    }
}

/// Collapsed reasoning block: a dim "thought" row that expands to the model's
/// full chain of thought. Live (still reasoning) shows the dot wave.
struct ThinkingDisclosure: View {
    let text: String
    var isLive: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Brand.fgDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain").font(.system(size: 10))
                Text(isLive ? "Thinking…" : "Thoughts")
                    .font(.caption)
                if isLive { BouncingDots(color: Brand.fgFaint) }
            }
            .foregroundStyle(Brand.fgFaint)
        }
        .accessibilityIdentifier("chat-thinking-block")
    }
}

/// Three dots bobbing in a staggered wave — the chat's "model is working"
/// motion, sibling to the sidebar's EqualizerBars (which stays the audio cue).
struct BouncingDots: View {
    var color: Color = Brand.fgDim
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .offset(y: animating ? -3 : 2)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animating)
            }
        }
        .frame(width: 24, height: 14)
        .onAppear { animating = true }
    }
}
