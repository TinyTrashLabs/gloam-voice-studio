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
    var isStreaming = false
    var streamingText = ""
    var chatError: String?
    /// Non-blocking: reply text arrived but speech synthesis had a problem.
    var speechWarning: String?
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
        refresh()
    }

    // MARK: send / stop

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard app.downloads.state(for: app.chatLLM) == .ready else {
            chatError = "Download the \(app.chatLLM.rawValue) model first (chat panel → Model)."
            return
        }
        if current == nil { newConversation() }
        guard var convo = current else { return }

        draft = ""
        chatError = nil
        speechWarning = nil
        // Title from the first *user* message — a seeded persona greeting
        // shouldn't leave every new chat titled "New Chat".
        if !convo.messages.contains(where: { $0.role == "user" }) {
            convo.title = Conversation.deriveTitle(from: text)
        }
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "user", text: text,
            createdAt: ChatStore.timestamp()))
        commit(convo)

        let request = makeRequest(for: convo)
        let convoID = convo.id
        isStreaming = true
        streamingText = ""
        streamTask = Task { [weak self] in
            guard let self else { return }
            var sawFinished = false
            do {
                let stream = await self.app.engine.chatStream(
                    backend: self.app.chatLLM, request: request)
                for try await event in stream {
                    switch event {
                    case .delta(let d):
                        self.streamingText += d
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
            self.isStreaming = false
            self.streamingText = ""
            self.streamTask = nil
        }
    }

    /// Stop button: cancels the in-flight stream AND clears queued speech.
    func stop() {
        streamTask?.cancel()
        speechTask?.cancel()
        speech.stop()
    }

    /// Replay an assistant message (or speak it for the first time).
    func speak(_ message: ChatMessage) {
        guard let convo = current else { return }
        speechTask?.cancel()
        speech.stop()
        speakText(message.text, voiceSlug: convo.voiceSlug)
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
        let budget = max(app.chatLLM.contextTokens - sampling.maxTokens - 256, 512)
        let trimmed = ChatContextWindow.trim(turns: turns, budgetTokens: budget)
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
            disableThinking: true)
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
        let isCurrent = current?.id == convoID
        commit(convo)
        // Stats + audio belong to the visible conversation only; a reply for
        // a background conversation is persisted silently.
        guard isCurrent else { return }
        lastStats = stats
        if app.chatAutoSpeak {
            speakText(result.text, voiceSlug: convo.voiceSlug)
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

    /// Sentence-chunked synthesis into the FIFO queue. Uses the current Studio
    /// TTS backend + the conversation's voice; skips history (chat replies
    /// would flood it). TTS problems warn — they never lose the text reply.
    private func speakText(_ text: String, voiceSlug: String) {
        // Cancel any speech already in flight — finishReply's auto-speak path
        // calls this directly (without going through speak()'s cancel), and
        // without it two replies' audio could interleave and an orphaned task
        // would escape stop(). Harmless redundancy when speak() already did it.
        speechTask?.cancel()
        speech.stop()
        speechGeneration += 1
        let generation = speechGeneration
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.speechGeneration == generation { self.speechTask = nil } }
            for sentence in SentenceSplitter.split(text) {
                if Task.isCancelled { return }
                do {
                    let result = try await self.app.synthesizeLine(
                        text: sentence, voiceSlug: voiceSlug,
                        emotion: .neutral, speed: 1.0, recordHistory: false)
                    // Re-check after the await: stop() may have cleared the
                    // queue while this sentence was mid-synthesis.
                    if Task.isCancelled { return }
                    let wav = WAVEncoder.encode(
                        pcm16: PCM16.data(from: result.samples),
                        sampleRate: result.sampleRate)
                    self.speech.enqueue(wav: wav)
                } catch {
                    self.speechWarning = "Speech unavailable: \(self.app.describeAny(error))"
                    return
                }
            }
        }
    }
}
