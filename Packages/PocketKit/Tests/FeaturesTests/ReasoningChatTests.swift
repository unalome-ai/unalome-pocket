import ChatCore
import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Features

/// Streams fixed events and records what it was asked.
private final class FixedEngine: ChatEngine {
    let displayName = "Fixed"
    let capabilities: EngineCapabilities
    let events: [GenerationEvent]
    let calls = Mutex<[(turn: ChatTurn, history: [ChatTurn], options: GenerationOptions)]>([])

    init(events: [GenerationEvent], supportsThinking: Bool = true) {
        self.events = events
        capabilities = EngineCapabilities(supportsVision: false, maxContextTokens: 1024, supportsThinking: supportsThinking)
    }

    func load(progress: @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func reply(to turn: ChatTurn, history: [ChatTurn], options: GenerationOptions)
        -> AsyncThrowingStream<GenerationEvent, Error>
    {
        calls.withLock { $0.append((turn, history, options)) }
        let events = events
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor
struct ReasoningChatTests {
    private let store: ConversationStore
    private let conversation: Conversation
    private let container: ModelContainer

    init() throws {
        container = try ConversationStore.makeContainer(inMemory: true)
        store = ConversationStore(context: container.mainContext)
        conversation = try store.createConversation()
    }

    private func model(_ engine: FixedEngine) -> ChatViewModel {
        ChatViewModel(conversation: conversation, store: store, host: EngineHost(choice: .scripted) { _ in engine })
    }

    @Test func reasoningIsStoredApartAndNeverSentBack() async throws {
        let engine = FixedEngine(events: [
            .reasoning("The user greets me."), .token("Hello!"), .stats(tokensPerSecond: 10), .done,
        ])
        let model = model(engine)
        model.isThinkingEnabled = true
        model.draft = "Hi"
        model.send()
        await model.waitForGeneration()

        let reply = try #require(model.messages.last)
        #expect(reply.text == "Hello!")
        #expect(reply.reasoning == "The user greets me.")
        #expect(reply.reasoningSeconds != nil)

        model.draft = "And again"
        model.send()
        await model.waitForGeneration()
        let second = try #require(engine.calls.withLock { $0.last })
        #expect(second.history.map(\.text) == ["Hi", "Hello!"])
        #expect(!second.history.contains { $0.text.contains("greets") })
    }

    @Test func thinkingIsOffByDefaultAndPerChat() async throws {
        let engine = FixedEngine(events: [.token("ok"), .done])
        let model = model(engine)
        #expect(!model.isThinkingEnabled)
        model.draft = "Hi"
        model.send()
        await model.waitForGeneration()
        #expect(engine.calls.withLock { $0.last?.options.thinking } == false)
        #expect(engine.calls.withLock { $0.last?.options.maxTokens } == GenerationOptions.defaultMaxTokens)

        model.isThinkingEnabled = true
        #expect(conversation.isThinkingEnabled)
        model.regenerate()
        await model.waitForGeneration()
        #expect(engine.calls.withLock { $0.last?.options.thinking } == true)
        #expect(engine.calls.withLock { $0.last?.options.maxTokens } == GenerationOptions.thinkingMaxTokens)
    }

    @Test func thinkingSwitchIsIgnoredForModelsWithoutIt() async throws {
        let engine = FixedEngine(events: [.token("ok"), .done], supportsThinking: false)
        let model = model(engine)
        model.isThinkingEnabled = true
        #expect(!model.supportsThinking)
        model.draft = "Hi"
        model.send()
        await model.waitForGeneration()
        #expect(engine.calls.withLock { $0.last?.options.thinking } == false)
    }

    @Test func lengthLimitIsShownAndCanBeContinued() async throws {
        let engine = FixedEngine(events: [.token("Part one"), .lengthLimitReached, .done])
        let model = model(engine)
        model.draft = "Write a lot"
        model.send()
        await model.waitForGeneration()

        let reply = try #require(model.messages.last)
        #expect(reply.stoppedAtLengthLimit)
        #expect(model.canContinue)

        model.continueReply()
        await model.waitForGeneration()
        #expect(model.messages.count == 2, "continuing appends to the same reply")
        #expect(reply.text == "Part onePart one")
        let call = try #require(engine.calls.withLock { $0.last })
        #expect(call.history.last?.text == "Part one")
        #expect(call.turn.role == .user)
    }

    @Test func memoryIsReportedWithTheSpeed() async throws {
        let usage = MemoryUsage(peakBytes: 2_000_000_000, processFootprintBytes: 2_400_000_000)
        let engine = FixedEngine(events: [.token("ok"), .stats(tokensPerSecond: 15), .memory(usage), .done])
        let model = model(engine)
        var metrics: ReplyMetrics?
        model.onReplyFinished = { _, reported in metrics = reported }
        model.draft = "Hi"
        model.send()
        await model.waitForGeneration()
        #expect(metrics == ReplyMetrics(tokensPerSecond: 15, memory: usage))
    }
}
