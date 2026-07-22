import EngineKit
import Foundation
import Observation
import StudioKit

/// Sampling settings for the chat inspector. Essentials (temperature,
/// maxTokens) sit in the panel; the rest live behind the Advanced disclosure.
/// 0 means "off" for topK/minP/penalties (mapped to nil on the request).
struct ChatSamplingSettings: Codable, Equatable {
    var temperature: Float = 0.7
    var maxTokens: Int = 512
    var topP: Float = 1.0
    var topK: Int = 0
    var minP: Float = 0
    var repetitionPenalty: Float = 0
    var presencePenalty: Float = 0
    var frequencyPenalty: Float = 0
    static let defaults = ChatSamplingSettings()
}

/// Conversation state machine for the Chat tab: send → stream deltas →
/// finalize → speak (sentence-chunked FIFO). All GPU work goes through the
/// engine's serialized task chain, so chat and TTS can never collide.
@MainActor @Observable
final class ChatController {
    private unowned let app: AppModel
    let store: ChatStore
    let speech = ChatSpeechQueue()

    var conversations: [Conversation] = []
    var current: Conversation?
    var draft = ""
    /// Image staged for the next send (vision models). Copied into the chat
    /// attachments folder at attach time so the original can move/vanish.
    var pendingImage: URL?
    var isStreaming = false
    var streamingText = ""
    /// A sentence is currently rendering through the TTS model (drives the
    /// voice-activity indicator before/while audio plays).
    var isSynthesizing = false
    /// The composer mic is capturing. Speech output is silenced for the whole
    /// window — otherwise the voice's own reply plays into the mic and comes
    /// back as dictated text.
    private(set) var micCaptureActive = false
    var chatError: String?
    /// Non-blocking: reply text arrived but speech synthesis had a problem.
    var speechWarning: String?
    /// Message ids with an explicit, user-triggered synthesis in flight (a
    /// speaker click with no cached take yet, or a Regenerate selection) —
    /// drives the spinner state on that bubble's speaker icon so a second
    /// click can't race it into double-synthesizing.
    var pendingAudioMessageIDs: Set<String> = []
    var lastStats: ChatMessageStats?
    var sampling: ChatSamplingSettings {
        didSet {
            if let data = try? JSONEncoder().encode(sampling) {
                UserDefaults.standard.set(data, forKey: "chatSampling")
            }
        }
    }

    private var streamTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    /// Monotonic token so a finished speech task only clears `speechTask`
    /// if it hasn't been superseded by a newer one.
    private var speechGeneration = 0

    // Speak-while-generating: sentences detected mid-stream queue here and one
    // sequential consumer synthesizes them through the engine's interleaved
    // path (GPU-idle gaps between token pulls) and hands the audio to the
    // playback queue — so the reply starts speaking while tokens are still
    // generating. The consumer BATCHES whatever queued while the previous
    // synthesis ran: TTS calls carry a ~5s fixed cost (the clone reference is
    // re-processed per call), so per-sentence calls are mostly overhead.
    private var liveSegmenter = LiveSpeechSegmenter()
    private var liveQueue: [String] = []
    private var liveSignal: AsyncStream<Void>.Continuation?
    private var liveSpokeAnything = false
    /// The user replayed another message mid-stream — their choice wins; the
    /// streaming reply must not auto-speak when it finishes.
    private var liveSpeechInterrupted = false

    // Reply-audio auto-save (chatAutoSpeak-on path): accumulates the chunk
    // samples already being synthesized for playback so the whole reply can
    // be saved as one take once it finishes — no extra synthesis calls.
    // pendingSaveMessageID is stamped by finishReply once the message
    // exists; finishPendingSave() no-ops if it was never stamped (that
    // happens when chatAutoSpeak is off — see Task 5, which handles that
    // case via an explicit, user-triggered synthesis instead).
    private var pendingSaveChunks: [[Float]] = []
    private var pendingSaveSampleRate: Int?
    private var pendingSaveBackend: BackendID?
    private var pendingSaveConvoID: String?
    private var pendingSaveMessageID: String?

    init(app: AppModel, store: ChatStore) {
        self.app = app
        self.store = store
        if let data = UserDefaults.standard.data(forKey: "chatSampling"),
           let decoded = try? JSONDecoder().decode(ChatSamplingSettings.self, from: data) {
            sampling = decoded
        } else {
            sampling = .defaults
        }
    }

    func resetSampling() { sampling = .defaults }

    // MARK: conversations

    /// Conversations for the sidebar-selected voice, newest first.
    func refresh() {
        guard let slug = app.selectedVoiceSlug else { conversations = []; return }
        conversations = store.list(voiceSlug: slug)
        if let current, !conversations.contains(where: { $0.id == current.id }) {
            self.current = conversations.first
        }
        if current == nil { current = conversations.first }
    }

    func newConversation() {
        guard let slug = app.selectedVoiceSlug else { return }
        stop()
        var convo = Conversation.new(voiceSlug: slug)
        // Seed the persona's greeting as the opening message, if any — but
        // never auto-speak it (surprise audio on a voice click would be worse
        // than a silent bubble; the replay button covers it).
        if let greeting = (try? app.voices.get(slug).meta)?.persona?.greeting,
           !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            convo.messages.append(ChatMessage(
                id: UUID().uuidString, role: "assistant", text: greeting,
                createdAt: ChatStore.timestamp()))
        }
        current = convo
        conversations.insert(convo, at: 0)
        // Not saved until the first message — empty chats shouldn't persist.
    }

    func select(_ conversation: Conversation) {
        guard conversation.id != current?.id else { return }
        stop()
        current = conversation
    }

    func deleteConversation(_ conversation: Conversation) {
        if conversation.id == current?.id { stop(); current = nil }
        try? store.delete(conversation.id)
        app.chatAudioStore.deleteAll(conversationID: conversation.id)
        refresh()
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = conversation
        updated.title = trimmed
        commit(updated)
    }

    /// A voice was renamed (re-slugged): re-point its conversations, then
    /// reload whatever we hold in memory so the open chat follows along.
    func voiceRenamed(from old: String, to new: String) {
        store.migrateVoiceSlug(from: old, to: new)
        if let cur = current, cur.voiceSlug == old {
            current = store.load(cur.id)
        }
        refresh()
    }

    // MARK: send / stop

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        if current == nil { newConversation() }
        guard var convo = current else { return }

        draft = ""
        chatError = nil
        speechWarning = nil
        let attachments = app.chatLLM.supportsVision ? pendingImage.map { [$0.path] } : nil
        pendingImage = nil
        // Title from the first *user* message — a seeded persona greeting
        // shouldn't leave every new chat titled "New Chat".
        if !convo.messages.contains(where: { $0.role == "user" }) {
            convo.title = Conversation.deriveTitle(from: text)
        }
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "user", text: text,
            createdAt: ChatStore.timestamp(), attachments: attachments))
        commit(convo)
        startStream(for: convo)
    }

    /// Stage an image for the next send: copied into the conversation
    /// attachments folder so the original file can move or disappear.
    func attachImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let dir = store.directory.appendingPathComponent("attachments")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(
                UUID().uuidString + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
            try FileManager.default.copyItem(at: url, to: dest)
            pendingImage = dest
        } catch {
            chatError = "Couldn't attach image: \(app.describeAny(error))"
        }
    }

    /// Regenerate after a failed reply: drop trailing errored partials so the
    /// request is clean, then re-stream for the same last user message.
    func retry() {
        guard !isStreaming, var convo = current else { return }
        chatError = nil
        speechWarning = nil
        while let last = convo.messages.last, last.role == "assistant", last.errored == true {
            convo.messages.removeLast()
        }
        guard convo.messages.last?.role == "user" else { return }
        commit(convo)
        startStream(for: convo)
    }

    /// Kick off the streaming reply for a conversation whose last message is
    /// the user turn to answer. Shared by send() and retry().
    private func startStream(for convo: Conversation) {
        let request = makeRequest(for: convo)
        let convoID = convo.id
        isStreaming = true
        streamingText = ""
        if app.chatAutoSpeak, !micCaptureActive {
            startLiveSpeech(voiceSlug: convo.voiceSlug, convoID: convo.id)
        }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var sawFinished = false
            do {
                try await self.app.ensureLLMReady(self.app.chatLLM)
                let stream = await self.app.engine.chatStream(
                    backend: self.app.chatLLM, request: request)
                for try await event in stream {
                    switch event {
                    case .delta(let d):
                        self.streamingText += d
                        self.feedLiveSentences(self.liveSegmenter.consume(d))
                    case .finished(let result):
                        sawFinished = true
                        self.finishReply(result, convoID: convoID)
                    }
                }
                // Cancelling the consuming task makes `for try await` end
                // normally with no error — it does NOT throw CancellationError
                // — so a Stop mid-stream lands here, not in the catch below.
                if !sawFinished, Task.isCancelled {
                    self.keepPartialReply(convoID: convoID)
                }
            } catch is CancellationError {
                // Belt-and-braces: kept in case a future producer does throw on
                // cancellation.
                self.keepPartialReply(convoID: convoID)
            } catch {
                self.failReply(self.app.describeAny(error), convoID: convoID)
            }
            // Normal finishes close the feed in finishReply (after the final
            // sentences are queued); this covers cancel/error exits.
            self.endLiveSpeech()
            self.isStreaming = false
            self.streamingText = ""
            self.streamTask = nil
        }
    }

    /// Composer mic opened/closed. While the mic is capturing, all speech
    /// output stops and stays off (echo guard: the reply would be transcribed
    /// straight back into the draft). Text streaming continues untouched.
    func setMicCapture(_ active: Bool) {
        micCaptureActive = active
        guard active else { return }
        if liveSignal != nil {
            endLiveSpeech()
            liveSpeechInterrupted = true
        }
        speechTask?.cancel()
        speech.stop()
        isSynthesizing = false
    }

    /// Stop button: cancels the in-flight stream AND clears queued speech.
    func stop() {
        streamTask?.cancel()
        endLiveSpeech()
        speechTask?.cancel()
        speech.stop()
        isSynthesizing = false
    }

    /// Synthesizes the entire reply text in one non-chunked pass, saves it
    /// as a new take, and (if `play`) enqueues it for playback once ready.
    /// Called only in response to an explicit user action (a speaker click
    /// with no cached take, or a Regenerate selection) — never invoked
    /// automatically or in the background.
    private func synthesizeWholeReplyAndSave(message: ChatMessage, convoID: String,
                                             backend: BackendID, play: Bool) async {
        pendingAudioMessageIDs.insert(message.id)
        defer { pendingAudioMessageIDs.remove(message.id) }
        guard let convo = conversation(for: convoID) else { return }
        do {
            let result = try await app.synthesizeLine(
                text: message.text, voiceSlug: convo.voiceSlug,
                emotion: .neutral, speed: 1.0, recordHistory: false,
                backendOverride: backend)
            let wav = WAVEncoder.encode(pcm16: PCM16.data(from: result.samples),
                                        sampleRate: result.sampleRate)
            let seconds = Double(result.samples.count) / Double(result.sampleRate)
            let entry = try app.chatAudioStore.save(
                wav: wav, conversationID: convoID, messageID: message.id,
                backend: backend.rawValue, sampleRate: result.sampleRate,
                seconds: seconds, wallMs: Int(result.wallSeconds * 1000))
            guard var freshConvo = conversation(for: convoID),
                  let index = freshConvo.messages.firstIndex(where: { $0.id == message.id })
            else { return }
            freshConvo.messages[index].audioTakeIDs =
                (freshConvo.messages[index].audioTakeIDs ?? []) + [entry.id]
            freshConvo.messages[index].currentTakeID = entry.id
            commit(freshConvo)
            if play {
                speechTask?.cancel()
                speech.stop()
                speech.enqueue(wav: wav, text: message.text,
                               voiced: ChatSpeechQueue.voicedBounds(
                                   samples: result.samples, sampleRate: result.sampleRate))
            }
        } catch {
            speechWarning = "Speech unavailable: \(app.describeAny(error))"
        }
    }

    /// Regenerate a reply's audio with a specific model, chosen from the
    /// bubble's menu. Checks the same download/license preconditions
    /// Studio's Generate already does; if either blocks, stashes this as
    /// the pending action so the shared prompt sheet resumes it once
    /// cleared (see AppModel.PendingSynthesisAction).
    func regenerateAudio(for message: ChatMessage, backend: BackendID) async {
        guard let convo = current else { return }
        if backend.spec.needsLicenseAck && !app.didAck(backend) {
            app.pendingSynthesisAction = .chatRegenerate(
                conversationID: convo.id, messageID: message.id, backend: backend)
            app.licensePromptBackend = backend
            return
        }
        if app.downloads.state(for: backend) != .ready {
            app.pendingSynthesisAction = .chatRegenerate(
                conversationID: convo.id, messageID: message.id, backend: backend)
            app.downloadPrompt = backend
            return
        }
        await synthesizeWholeReplyAndSave(
            message: message, convoID: convo.id, backend: backend, play: true)
    }

    /// Re-resolves the conversation/message fresh by id and re-runs
    /// regenerate — called after a download/license prompt clears, when the
    /// state that triggered it may be stale (conversation switched, message
    /// deleted in the meantime). No-ops if either is gone.
    func resumeRegenerate(conversationID: String, messageID: String, backend: BackendID) async {
        guard let convo = conversation(for: conversationID),
              let message = convo.messages.first(where: { $0.id == messageID })
        else { return }
        await synthesizeWholeReplyAndSave(
            message: message, convoID: conversationID, backend: backend, play: true)
    }

    /// Switch which saved take is active for a reply — instant, no
    /// synthesis, no file changes.
    func setCurrentTake(_ takeID: String, for message: ChatMessage) {
        guard var convo = current,
              let index = convo.messages.firstIndex(where: { $0.id == message.id })
        else { return }
        convo.messages[index].currentTakeID = takeID
        commit(convo)
    }

    /// Replay an assistant message. If it has a cached take, plays it
    /// directly — instant, no synthesis. Otherwise (chatAutoSpeak was off
    /// when this reply generated, or the take was pruned) synthesizes it
    /// on demand and saves the result as a take for next time.
    func speak(_ message: ChatMessage) {
        guard let convo = current else { return }
        // Echo guard: no speech while the composer mic is capturing.
        guard !micCaptureActive else { return }
        // A synthesis is already in flight for this exact message — ignore
        // the click rather than racing a second synthesis.
        guard !pendingAudioMessageIDs.contains(message.id) else { return }
        // Replaying while a reply is streaming-and-speaking is a user
        // override: close the live feed (its consumer is about to be
        // cancelled — sentences queued for a dead consumer would silently
        // vanish) and don't resume auto-speech for that reply on finish.
        func interruptLiveSpeechIfNeeded() {
            if liveSignal != nil {
                endLiveSpeech()
                liveSpeechInterrupted = true
            }
        }
        if let takeID = message.currentTakeID,
           let url = try? app.chatAudioStore.wavURL(takeID),
           let wav = try? Data(contentsOf: url) {
            interruptLiveSpeechIfNeeded()
            speechTask?.cancel()
            speech.stop()
            speech.enqueue(wav: wav, text: message.text, voiced: nil)
            return
        }
        interruptLiveSpeechIfNeeded()
        speechTask?.cancel()
        speech.stop()
        Task { await synthesizeWholeReplyAndSave(
            message: message, convoID: convo.id, backend: app.chatTTSBackend, play: true) }
    }

    // MARK: internals

    private func makeRequest(for convo: Conversation) -> ChatRequest {
        let meta = try? app.voices.get(convo.voiceSlug).meta
        let system = PersonaPromptBuilder.systemPrompt(
            voiceName: meta?.name ?? convo.voiceSlug, persona: meta?.persona)
        var turns = [ChatTurn(role: .system, content: system)]
        turns += convo.messages.map {
            ChatTurn(role: $0.role == "user" ? .user : .assistant, content: $0.text)
        }
        // Headroom: reply budget + 256 tokens of template/tool slack. Floor
        // keeps the budget sane if maxTokens approaches the context window.
        // The user's context setting caps history; the model's limit caps both.
        let window = min(app.chatContextTokens, app.chatLLM.contextTokens)
        let budget = max(window - sampling.maxTokens - 256, 512)
        let trimmed = ChatContextWindow.trim(turns: turns, budgetTokens: budget)
        // Vision: only the LAST user turn's attachments ride along (v1 —
        // earlier turns' images aren't re-encoded every request).
        let images: [URL]? = app.chatLLM.supportsVision
            ? convo.messages.last(where: { $0.role == "user" })?.attachments?
                .map { URL(fileURLWithPath: $0) }
            : nil
        return ChatRequest(
            messages: trimmed,
            temperature: sampling.temperature,
            topP: sampling.topP == 1.0 ? nil : sampling.topP,
            maxTokens: sampling.maxTokens,
            topK: sampling.topK == 0 ? nil : sampling.topK,
            minP: sampling.minP == 0 ? nil : sampling.minP,
            repetitionPenalty: sampling.repetitionPenalty == 0 ? nil : sampling.repetitionPenalty,
            presencePenalty: sampling.presencePenalty == 0 ? nil : sampling.presencePenalty,
            frequencyPenalty: sampling.frequencyPenalty == 0 ? nil : sampling.frequencyPenalty,
            disableThinking: !(app.chatThinking && app.chatLLM.thinkingSupport == .toggle),
            imageURLs: images)
    }

    /// Resolve the conversation a stream was started for: prefer `current`,
    /// then the sidebar list, then disk. nil = deleted mid-stream, in which
    /// case the reply is dropped — deletion wins.
    private func conversation(for id: String) -> Conversation? {
        if let current, current.id == id { return current }
        if let listed = conversations.first(where: { $0.id == id }) { return listed }
        return store.load(id)
    }

    private func finishReply(_ result: ChatResult, convoID: String) {
        guard var convo = conversation(for: convoID) else { return }
        let stats = ChatMessageStats(
            promptTokens: result.usage.promptTokens,
            completionTokens: result.usage.completionTokens,
            tokensPerSecond: result.tokensPerSecond,
            wallSeconds: result.wallSeconds)
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "assistant", text: result.text,
            createdAt: ChatStore.timestamp(), stats: stats))
        let messageID = convo.messages.last!.id
        let isCurrent = current?.id == convoID
        commit(convo)
        // Stats + audio belong to the visible conversation only; a reply for
        // a background conversation is persisted silently.
        guard isCurrent else { return }
        lastStats = stats
        guard app.chatAutoSpeak, !micCaptureActive else { return }
        if liveSpeechInterrupted {
            liveSpeechInterrupted = false
            return
        }
        // The audio about to be synthesized (live-speech tail, or the
        // speakText fallback below) belongs to THIS reply — stamp it now
        // that the message exists, so finishPendingSave can attach it.
        pendingSaveMessageID = messageID
        if liveSignal != nil {
            // Speak-while-generating was active: queue whatever the stream
            // hadn't completed yet, then close the feed.
            let rest = liveSegmenter.finish(finalText: result.text)
            if liveSegmenter.derailed && !liveSpokeAnything {
                // Live feed never proved trustworthy and nothing played —
                // fall back to speaking the authoritative final text whole.
                endLiveSpeech()
                speakText(result.text, voiceSlug: convo.voiceSlug, convoID: convoID)
            } else {
                feedLiveSentences(rest)
                endLiveSpeech()
            }
        } else {
            speakText(result.text, voiceSlug: convo.voiceSlug, convoID: convoID)
        }
    }

    /// Cancellation mid-stream: keep whatever text arrived, marked errored.
    private func keepPartialReply(convoID: String) {
        let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty, var convo = conversation(for: convoID) else { return }
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "assistant", text: partial,
            createdAt: ChatStore.timestamp(), errored: true))
        commit(convo)
    }

    private func failReply(_ message: String, convoID: String) {
        chatError = message
        keepPartialReply(convoID: convoID)
    }

    /// Persist + refresh the row in `conversations`; reassign `current` only
    /// when this is still the visible conversation (in-flight replies for a
    /// switched-away conversation must not hijack the selection).
    private func commit(_ convo: Conversation) {
        var updated = convo
        updated.updatedAt = ChatStore.timestamp()
        if current?.id == updated.id { current = updated }
        try? store.save(updated)
        if let i = conversations.firstIndex(where: { $0.id == updated.id }) {
            conversations[i] = updated
        } else if updated.voiceSlug == app.selectedVoiceSlug {
            conversations.insert(updated, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Hands completed sentences to the live-speech consumer.
    private func feedLiveSentences(_ sentences: [String]) {
        guard liveSignal != nil, !sentences.isEmpty else { return }
        liveQueue.append(contentsOf: sentences)
        liveSignal?.yield(())
    }

    /// Speak-while-generating pipeline: one sequential consumer drains the
    /// sentence queue, synthesizes through the engine's interleaved path (it
    /// runs in the GPU-idle gaps between token pulls), and hands audio to the
    /// playback queue in order. Each pass takes EVERYTHING queued (capped) as
    /// one TTS call: the first sentence goes out alone for fastest first
    /// audio, and the batching then amortizes the ~5s per-call fixed cost
    /// (clone-reference processing) across the sentences that accumulated
    /// while the previous call rendered.
    private func startLiveSpeech(voiceSlug: String, convoID: String) {
        speechTask?.cancel()
        speech.stop()
        liveSegmenter = LiveSpeechSegmenter()
        liveQueue.removeAll()
        liveSpokeAnything = false
        liveSpeechInterrupted = false
        pendingSaveChunks = []
        pendingSaveSampleRate = nil
        pendingSaveBackend = nil
        pendingSaveConvoID = convoID
        pendingSaveMessageID = nil
        // pendingSaveMessageID is stamped later by finishReply.
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        liveSignal = continuation
        speechGeneration += 1
        let generation = speechGeneration
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.speechGeneration == generation {
                    self.speechTask = nil
                    self.isSynthesizing = false
                    self.finishPendingSave()
                }
            }
            for await _ in signals {
                while !self.liveQueue.isEmpty {
                    if Task.isCancelled { return }
                    // Batch what's queued, capped so one giant paragraph
                    // doesn't become a single long stall.
                    var chunk = self.liveQueue.removeFirst()
                    while let next = self.liveQueue.first, chunk.count + next.count < 280 {
                        self.liveQueue.removeFirst()
                        chunk += " " + next
                    }
                    do {
                        self.setSynthesizing(true, ifGeneration: generation)
                        let result = try await self.synthesizeChatLine(chunk, voiceSlug: voiceSlug)
                        self.setSynthesizing(false, ifGeneration: generation)
                        if Task.isCancelled { return }
                        self.pendingSaveChunks.append(result.samples)
                        self.pendingSaveSampleRate = result.sampleRate
                        self.pendingSaveBackend = self.app.chatTTSBackend
                        // Edge fades: consecutive chunks play back-to-back;
                        // without them the seams can click.
                        let faded = AudioAssembler.fadeEdges(
                            result.samples, sampleRate: result.sampleRate)
                        let wav = WAVEncoder.encode(
                            pcm16: PCM16.data(from: faded),
                            sampleRate: result.sampleRate)
                        self.speech.enqueue(
                            wav: wav, text: chunk,
                            voiced: ChatSpeechQueue.voicedBounds(
                                samples: faded, sampleRate: result.sampleRate))
                        self.liveSpokeAnything = true
                    } catch {
                        self.setSynthesizing(false, ifGeneration: generation)
                        // A Stop press cancels the stream's tail task, which can
                        // reject the in-flight synthesis — that's the user's own
                        // action, not a speech problem worth a warning banner.
                        if error is CancellationError || Task.isCancelled { return }
                        self.speechWarning = "Speech unavailable: \(self.app.describeAny(error))"
                        return
                    }
                }
            }
        }
    }

    /// Closes the sentence feed; the consumer drains what's queued, then ends.
    private func endLiveSpeech() {
        liveSignal?.finish()
        liveSignal = nil
    }

    /// Sentence-chunked synthesis into the FIFO queue. Uses the current Studio
    /// TTS backend + the conversation's voice; skips history (chat replies
    /// would flood it). TTS problems warn — they never lose the text reply.
    private func speakText(_ text: String, voiceSlug: String, convoID: String) {
        // Cancel any speech already in flight — finishReply's auto-speak path
        // calls this directly (without going through speak()'s cancel), and
        // without it two replies' audio could interleave and an orphaned task
        // would escape stop(). Harmless redundancy when speak() already did it.
        speechTask?.cancel()
        speech.stop()
        speechGeneration += 1
        let generation = speechGeneration
        pendingSaveChunks = []
        pendingSaveSampleRate = nil
        pendingSaveBackend = nil
        pendingSaveConvoID = convoID
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.speechGeneration == generation {
                    self.speechTask = nil
                    self.isSynthesizing = false
                    self.finishPendingSave()
                }
            }
            // Reasoning is never spoken (idempotent when already clean).
            for sentence in SentenceSplitter.split(stripThinking(text)) {
                if Task.isCancelled { return }
                do {
                    self.setSynthesizing(true, ifGeneration: generation)
                    let result = try await self.synthesizeChatLine(sentence, voiceSlug: voiceSlug)
                    self.setSynthesizing(false, ifGeneration: generation)
                    // Re-check after the await: stop() may have cleared the
                    // queue while this sentence was mid-synthesis.
                    if Task.isCancelled { return }
                    self.pendingSaveChunks.append(result.samples)
                    self.pendingSaveSampleRate = result.sampleRate
                    self.pendingSaveBackend = self.app.chatTTSBackend
                    let faded = AudioAssembler.fadeEdges(
                        result.samples, sampleRate: result.sampleRate)
                    let wav = WAVEncoder.encode(
                        pcm16: PCM16.data(from: faded),
                        sampleRate: result.sampleRate)
                    self.speech.enqueue(
                        wav: wav, text: sentence,
                        voiced: ChatSpeechQueue.voicedBounds(
                            samples: faded, sampleRate: result.sampleRate))
                } catch {
                    self.setSynthesizing(false, ifGeneration: generation)
                    if error is CancellationError || Task.isCancelled { return }
                    self.speechWarning = "Speech unavailable: \(self.app.describeAny(error))"
                    return
                }
            }
        }
    }

    /// Guarded write: a superseded (cancelled) speech task resuming from its
    /// in-flight synthesis must not stomp the indicator a newer task owns.
    private func setSynthesizing(_ value: Bool, ifGeneration generation: Int) {
        if speechGeneration == generation { isSynthesizing = value }
    }

    /// Saves whatever's accumulated in `pendingSaveChunks` as a new take on
    /// the message `finishReply` stamped `pendingSaveMessageID` for, then
    /// clears the accumulator. Called from both speech tasks' `defer`
    /// blocks, so it fires on normal completion AND cancellation alike — a
    /// stopped-mid-reply take is still worth keeping. No-ops if
    /// `pendingSaveMessageID` was never stamped (chatAutoSpeak was off, so
    /// this accumulation was never meant to produce a take — see Task 5's
    /// separate on-demand path for that case) or if the conversation/message
    /// vanished (deleted) before this ran.
    private func finishPendingSave() {
        defer {
            pendingSaveChunks = []
            pendingSaveSampleRate = nil
            pendingSaveBackend = nil
            pendingSaveMessageID = nil
            pendingSaveConvoID = nil
        }
        guard !pendingSaveChunks.isEmpty,
              let sampleRate = pendingSaveSampleRate,
              let backend = pendingSaveBackend,
              let messageID = pendingSaveMessageID,
              let convoID = pendingSaveConvoID,
              var convo = conversation(for: convoID),
              let index = convo.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        let wav = ChatAudioAssembly.concatenateAndEncode(pendingSaveChunks, sampleRate: sampleRate)
        let totalSamples = pendingSaveChunks.reduce(0) { $0 + $1.count }
        let seconds = Double(totalSamples) / Double(sampleRate)
        guard let entry = try? app.chatAudioStore.save(
            wav: wav, conversationID: convoID, messageID: messageID,
            backend: backend.rawValue, sampleRate: sampleRate, seconds: seconds, wallMs: nil)
        else { return }
        convo.messages[index].audioTakeIDs = (convo.messages[index].audioTakeIDs ?? []) + [entry.id]
        convo.messages[index].currentTakeID = entry.id
        commit(convo)
    }

    /// One chat speech render, using the chat voice engine. Parallel mode
    /// (default) runs on the second GloamEngine so TTS overlaps token decode —
    /// gapless playback; off = the serialized fallback (interleaves with the
    /// stream in token gaps).
    private func synthesizeChatLine(_ text: String, voiceSlug: String) async throws -> SynthesisResult {
        if app.chatParallelSpeech {
            return try await app.synthesizeLine(
                text: text, voiceSlug: voiceSlug,
                emotion: .neutral, speed: 1.0, recordHistory: false,
                backendOverride: app.chatTTSBackend,
                engineOverride: app.chatSpeechEngine)
        }
        return try await app.synthesizeLine(
            text: text, voiceSlug: voiceSlug,
            emotion: .neutral, speed: 1.0, recordHistory: false,
            interleaved: true,
            backendOverride: app.chatTTSBackend)
    }
}
