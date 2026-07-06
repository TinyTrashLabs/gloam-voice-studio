import EngineKit
import StudioKit
import SwiftUI

/// Chat tab: conversations with the sidebar-selected voice. Layout mirrors
/// LM Studio: conversation list | transcript + composer | inspector.
struct ChatView: View {
    @Environment(AppModel.self) private var model

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
            Button("Delete", role: .destructive) { model.chat.deleteConversation(convo) }
        }
    }

    // MARK: transcript + composer

    private func transcriptColumn(voice: VoiceMeta) -> some View {
        @Bindable var chat = model.chat
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
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
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if let warning = chat.speechWarning {
                        Label(warning, systemImage: "speaker.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Start at the bottom (latest messages) on conversation switch and
            // stay pinned as the transcript grows — covers the user's own
            // just-sent bubble before the first token arrives, and politely
            // unpins if the user scrolls up (no onChange needed to reinforce it).
            .defaultScrollAnchor(.bottom)
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
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
                        Button { model.chat.speak(message) } label: {
                            if isSpeakingThis {
                                // Same EQ motif the sidebar uses for a playing
                                // sample — "this voice is speaking now".
                                EqualizerBars()
                            } else {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSpeakingThis ? Brand.accent : Brand.fgFaint)
                        .help(isSpeakingThis ? "Speaking…" : "Speak this reply")
                    }
                }
                if isStreamingBubble, message.text.isEmpty {
                    // Nothing has streamed back yet — first-send model load can
                    // take 10+ seconds, so show motion instead of a static "…".
                    HStack(spacing: 6) {
                        BouncingDots(color: Brand.fgDim)
                        Text("Thinking…").font(.caption).foregroundStyle(Brand.fgDim)
                    }
                    .accessibilityIdentifier("chat-thinking")
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

    private var composer: some View {
        @Bindable var chat = model.chat
        return HStack(alignment: .bottom, spacing: 10) {
            // Push-to-talk: dictate into the draft, then send as usual.
            // (Whisper emits its text after the mic stops — the button shows
            // its own transcribing spinner meanwhile.) While the mic is open,
            // speech output is silenced so the reply can't dictate itself.
            DictationButton(text: $chat.draft,
                            onActiveChange: { model.chat.setMicCapture($0) })
                .padding(.bottom, 10)
            TextField("Message \(voiceName())…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .accessibilityIdentifier("chat-composer")
                .onSubmit { model.chat.send() }
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
                .accessibilityIdentifier("chat-stop")
                .help("Stop generating / speaking")
            } else {
                Button { model.chat.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? Brand.fgFaint : Brand.accent)
                .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
