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
        let convo = Conversation.new(voiceSlug: slug)
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
        if convo.messages.isEmpty { convo.title = Conversation.deriveTitle(from: text) }
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "user", text: text,
            createdAt: ChatStore.timestamp()))
        commit(convo)

        let request = makeRequest(for: convo)
        isStreaming = true
        streamingText = ""
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = await self.app.engine.chatStream(
                    backend: self.app.chatLLM, request: request)
                for try await event in stream {
                    switch event {
                    case .delta(let d):
                        self.streamingText += d
                    case .finished(let result):
                        self.finishReply(result)
                    }
                }
            } catch is CancellationError {
                self.keepPartialReply()
            } catch {
                self.failReply(self.app.describeAny(error))
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
        // Headroom: reply budget + 256 tokens of template/tool slack.
        let budget = app.chatLLM.contextTokens - sampling.maxTokens - 256
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

    private func finishReply(_ result: ChatResult) {
        guard var convo = current else { return }
        let stats = ChatMessageStats(
            promptTokens: result.usage.promptTokens,
            completionTokens: result.usage.completionTokens,
            tokensPerSecond: result.tokensPerSecond,
            wallSeconds: result.wallSeconds)
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "assistant", text: result.text,
            createdAt: ChatStore.timestamp(), stats: stats))
        commit(convo)
        lastStats = stats
        if app.chatAutoSpeak {
            speakText(result.text, voiceSlug: convo.voiceSlug)
        }
    }

    /// Cancellation mid-stream: keep whatever text arrived, marked errored.
    private func keepPartialReply() {
        let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty, var convo = current else { return }
        convo.messages.append(ChatMessage(
            id: UUID().uuidString, role: "assistant", text: partial,
            createdAt: ChatStore.timestamp(), errored: true))
        commit(convo)
    }

    private func failReply(_ message: String) {
        chatError = message
        keepPartialReply()
    }

    /// Persist + refresh both `current` and its row in `conversations`.
    private func commit(_ convo: Conversation) {
        var updated = convo
        updated.updatedAt = ChatStore.timestamp()
        current = updated
        try? store.save(updated)
        if let i = conversations.firstIndex(where: { $0.id == updated.id }) {
            conversations[i] = updated
        } else {
            conversations.insert(updated, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Sentence-chunked synthesis into the FIFO queue. Uses the current Studio
    /// TTS backend + the conversation's voice; skips history (chat replies
    /// would flood it). TTS problems warn — they never lose the text reply.
    private func speakText(_ text: String, voiceSlug: String) {
        speechTask = Task { [weak self] in
            guard let self else { return }
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
