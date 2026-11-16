import ChatCore
import SwiftUI
import Foundation
import Observation

/// Drives one conversation: send, stream, stop, regenerate, edit and resend.
@MainActor
@Observable
public final class ChatViewModel {
    public let conversation: Conversation
    public var draft = ""
    /// The user message being edited; while set, `send()` edits and resends it.
    public private(set) var editingMessage: Message?
    public private(set) var isGenerating = false
    /// Decode speed of the current or most recent reply.
    public private(set) var tokensPerSecond: Double?
    public var errorMessage: String?

    /// The conversation's messages in order. Kept here, updated on append and delete,
    /// so views can read it cheaply while a reply streams.
    public private(set) var messages: [Message]

    /// The engine in use, its load state and its progress.
    public let host: EngineHost

    public var engineName: String { host.engine.displayName }

    /// Called with what each reply that ran to the end measured.
    public var onReplyFinished: ((EngineChoice, ReplyMetrics) -> Void)?
    /// Called whenever a reply is saved (finished or stopped), e.g. to refresh the widgets.
    public var onReplySaved: (() -> Void)?

    private let store: ConversationStore
    private let temperature: Double
    /// Overrides the length cap (tests); `nil` uses the default for the thinking setting.
    private let maxTokens: Int?
    private var generation: Generation?
    private var memoryUsage: MemoryUsage?
    /// When the streaming reply started reasoning, for the "Thinking… N s" label.
    public private(set) var reasoningStartedAt: Date?

    /// Images attached to the draft (file names in the attachment store), sent with the next message.
    public private(set) var draftAttachments: [String] = []

    /// The first message the model still saw in the latest reply, when older ones no longer fit
    /// its context window. The chat shows a one-line note above it.
    public private(set) var contextBoundaryMessageID: UUID?

    private struct Generation {
        let id: UUID
        let task: Task<Void, Never>
        let reply: Message
    }

    public init(
        conversation: Conversation,
        store: ConversationStore,
        host: EngineHost,
        temperature: Double = 0.7,
        maxTokens: Int? = nil
    ) {
        self.conversation = conversation
        self.messages = conversation.orderedMessages
        self.store = store
        self.host = host
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// The engine can reason before answering, so the thinking switch applies.
    public var supportsThinking: Bool {
        host.engine.capabilities.supportsThinking
    }

    /// Per-chat thinking switch. Off by default; only used when the engine supports it.
    public var isThinkingEnabled: Bool {
        get { conversation.isThinkingEnabled }
        set {
            conversation.isThinkingEnabled = newValue
            try? store.save()
        }
    }

    var options: GenerationOptions {
        GenerationOptions(
            temperature: persona?.temperature ?? temperature, maxTokens: maxTokens,
            thinking: supportsThinking && isThinkingEnabled)
    }

    // MARK: Persona

    private var personas: PersonaStore { PersonaStore(context: store.context) }

    /// The chat's persona. Its prompt is the system turn of every reply from the next one on.
    public var persona: Persona? {
        get {
            _ = personaRevision  // re-read after `persona` is set
            return personas.persona(id: conversation.personaID)
        }
        set {
            conversation.personaID = newValue?.id
            personaRevision += 1
            try? store.save()
        }
    }

    private var personaRevision = 0

    /// What the model is told before the conversation.
    var systemTurns: [ChatTurn] {
        guard let prompt = persona?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty
        else { return [] }
        return [ChatTurn(role: .system, text: prompt)]
    }

    // MARK: Attachments

    /// The engine accepts images.
    public var supportsImages: Bool {
        host.engine.capabilities.supportsVision && store.attachments != nil
    }

    public func url(forAttachment name: String) -> URL? {
        store.attachments?.url(for: name)
    }

    /// Downscales and stores an image for the next message.
    public func attachImage(_ data: Data) {
        guard let attachments = store.attachments else { return }
        do {
            draftAttachments.append(try attachments.save(imageData: data))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func removeDraftAttachment(_ name: String) {
        draftAttachments.removeAll { $0 == name }
        store.attachments?.delete([name])
    }

    /// The last reply was cut off (length limit, stopped, interrupted) and can be continued.
    public var canContinue: Bool {
        guard !isGenerating, let last = messages.last, last.role == .assistant, !last.text.isEmpty else { return false }
        return last.stoppedAtLengthLimit || last.wasInterrupted
    }

    /// The latest user message, the only one that can be edited and resent.
    public var lastUserMessage: Message? {
        messages.last { $0.role == .user }
    }

    public var canSend: Bool {
        !isGenerating && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    public var canRegenerate: Bool {
        !isGenerating && lastUserMessage != nil
    }

    // MARK: Actions

    public func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let editing = editingMessage {
                try deleteMessages(after: editing)
                editing.text = text
                conversation.updatedAt = .now
                try store.save()
                editingMessage = nil
            } else {
                messages.append(
                    try store.appendMessage(
                        role: .user, text: text, attachmentNames: draftAttachments, to: conversation))
                draftAttachments = []
            }
            draft = ""
            startGeneration()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops everything after the last user message and asks the engine again.
    public func regenerate() {
        guard canRegenerate, let lastUser = lastUserMessage else { return }
        do {
            try deleteMessages(after: lastUser)
            startGeneration()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops the reply. The text streamed so far is kept and saved.
    public func stop() {
        guard let generation else { return }
        generation.task.cancel()
        finish(generation, completed: false)
    }

    public func beginEditing(_ message: Message) {
        guard !isGenerating, message.id == lastUserMessage?.id else { return }
        editingMessage = message
        draft = message.text
    }

    public func cancelEditing() {
        editingMessage = nil
        draft = ""
    }

    /// Deletes images that were attached but never sent. Call when the chat closes.
    public func discardDraftAttachments() {
        store.attachments?.delete(draftAttachments)
        draftAttachments = []
    }

    /// Asks the model to carry on a reply that hit the length limit; the text is appended to it.
    public func continueReply() {
        guard canContinue, let reply = messages.last else { return }
        reply.stoppedAtLengthLimit = false
        reply.wasInterrupted = false
        let turn = ChatTurn(role: .user, text: "Continue exactly where you stopped, without repeating anything.")
        run(turn: turn, history: fittedHistory(messages, turn: turn), into: reply)
    }

    // MARK: Generation

    private func startGeneration() {
        guard let last = messages.last, last.role == .user else { return }
        let turn = last.turn(attachments: store.attachments)
        let history = fittedHistory(Array(messages.dropLast()), turn: turn)
        let reply: Message
        do {
            reply = try store.appendMessage(role: .assistant, text: "", to: conversation)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        messages.append(reply)
        run(turn: turn, history: history, into: reply)
    }

    /// The persona's system turn plus as much of `earlier` as fits the engine's context window
    /// next to `turn` and the reply. Updates `contextBoundaryMessageID`.
    private func fittedHistory(_ earlier: [Message], turn: ChatTurn) -> [ChatTurn] {
        let fit = ContextWindow.fit(
            history: systemTurns + earlier.map { $0.turn(attachments: store.attachments) },
            turn: turn,
            contextTokens: host.engine.capabilities.maxContextTokens,
            replyTokens: options.maxTokens)
        if fit.droppedCount == 0 {
            contextBoundaryMessageID = nil
        } else {
            // The first message still seen, or the message being answered if none fit.
            contextBoundaryMessageID = earlier.indices.contains(fit.droppedCount)
                ? earlier[fit.droppedCount].id : messages.last { $0.role == .user }?.id
        }
        return fit.history
    }

    private func run(turn: ChatTurn, history: [ChatTurn], into reply: Message) {
        errorMessage = nil
        tokensPerSecond = nil
        memoryUsage = nil
        reasoningStartedAt = nil
        isGenerating = true

        // The task inherits the main actor, so it can update the model directly.
        // It starts only after this method returns, by which time `generation` is set.
        // Every write is guarded by `id`: a stopped or replaced generation changes nothing.
        let id = UUID()
        let host = host
        let options = options
        let task = Task { [weak self] in
            do {
                try await host.ensureLoaded()
                let stream = host.engine.reply(to: turn, history: history, options: options)
                for try await event in stream {
                    guard let self, let current = self.generation, current.id == id else { return }
                    self.apply(event, to: current.reply)
                }
            } catch is CancellationError {
                // Usually `stop()`, which has already finished this generation. If not (the
                // engine was switched while it loaded), finish it here.
                guard let self, let current = self.generation, current.id == id else { return }
                self.finish(current, completed: false)
                return
            } catch {
                guard let self, let current = self.generation, current.id == id else { return }
                self.errorMessage = error.localizedDescription
                self.finish(current, completed: false)
                return
            }
            guard let self, let current = self.generation, current.id == id else { return }
            self.finish(current, completed: true)
        }
        generation = Generation(id: id, task: task, reply: reply)
    }

    private func apply(_ event: GenerationEvent, to reply: Message) {
        switch event {
        case .token(let token):
            endReasoning(of: reply)
            reply.text += token
        case .reasoning(let text):
            if reasoningStartedAt == nil { reasoningStartedAt = .now }
            reply.reasoning += text
        case .stats(let rate):
            tokensPerSecond = rate
        case .memory(let usage):
            memoryUsage = usage
        case .lengthLimitReached:
            reply.stoppedAtLengthLimit = true
        case .done:
            break
        }
    }

    private func endReasoning(of reply: Message) {
        guard let started = reasoningStartedAt, reply.reasoningSeconds == nil else { return }
        reply.reasoningSeconds = Date.now.timeIntervalSince(started)
    }

    /// Ends the generation and persists its reply; an empty reply is removed.
    private func finish(_ finished: Generation, completed: Bool) {
        generation = nil
        isGenerating = false
        let reply = finished.reply
        // The conversation may have been deleted while the reply streamed.
        guard reply.modelContext != nil, !reply.isDeleted else { return }
        endReasoning(of: reply)
        do {
            if reply.text.isEmpty && reply.reasoning.isEmpty {
                try store.deleteMessages([reply])
                messages.removeAll { $0.id == reply.id }
            } else {
                reply.wasInterrupted = !completed && !reply.stoppedAtLengthLimit
                conversation.updatedAt = .now
                try store.save()
                onReplySaved?()
                if completed {
                    // Streaming text is not announced token by token; say once that it is done.
                    AccessibilityNotification.Announcement("Reply finished").post()
                }
                if completed, tokensPerSecond != nil || memoryUsage != nil {
                    onReplyFinished?(host.choice, ReplyMetrics(tokensPerSecond: tokensPerSecond, memory: memoryUsage))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteMessages(after message: Message) throws {
        let later = messages.filter { $0.position > message.position }
        try store.deleteMessages(later)
        messages.removeAll { $0.position > message.position }
    }

    /// True while the reply waits for the engine to load.
    public var isLoadingModel: Bool {
        guard isGenerating, case .loading = host.state else { return false }
        return true
    }

    /// Waits for the running reply, if any, to finish. For tests.
    func waitForGeneration() async {
        await generation?.task.value
    }
}

/// What a finished reply measured.
public struct ReplyMetrics: Sendable, Equatable {
    public var tokensPerSecond: Double?
    public var memory: MemoryUsage?
}
