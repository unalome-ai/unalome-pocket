import ChatCore
import Foundation
import Synchronization
import SwiftData
import Testing
@testable import Features

@MainActor
struct ChatViewModelTests {
    private static let reply = Array(repeating: "token", count: 40).joined(separator: " ")

    private let container: ModelContainer
    private let store: ConversationStore
    private let conversation: Conversation

    init() throws {
        container = try ConversationStore.makeContainer(inMemory: true)
        store = ConversationStore(context: container.mainContext)
        conversation = try store.createConversation()
    }

    private func makeModel(tokenDelay: Duration = .milliseconds(1)) -> ChatViewModel {
        let engine = ScriptedEngine(replies: [Self.reply, "second reply"], tokenDelay: tokenDelay)
        return ChatViewModel(conversation: conversation, store: store, host: Self.host(engine))
    }

    @Test func sendStreamsAndSavesReply() async {
        let model = makeModel()
        model.draft = "  Hello  "
        model.send()

        #expect(model.isGenerating)
        #expect(model.draft.isEmpty)
        await model.waitForGeneration()

        #expect(!model.isGenerating)
        #expect(model.messages.map(\.role) == [.user, .assistant])
        #expect(model.messages.map(\.text) == ["Hello", Self.reply])
        #expect((model.tokensPerSecond ?? 0) > 0)
        #expect(conversation.title == "Hello")
        #expect(!container.mainContext.hasChanges)
    }

    @Test func sendIgnoresBlankDraft() {
        let model = makeModel()
        model.draft = "   \n"
        model.send()
        #expect(model.messages.isEmpty)
        #expect(!model.isGenerating)
    }

    @Test func stopKeepsAndSavesPartialReply() async throws {
        let model = makeModel(tokenDelay: .milliseconds(20))
        model.draft = "Hello"
        model.send()
        try await waitUntil { !(model.messages.last?.text.isEmpty ?? true) }

        model.stop()

        #expect(!model.isGenerating)
        let partial = try #require(model.messages.last)
        #expect(partial.role == .assistant)
        #expect(!partial.text.isEmpty)
        #expect(partial.text.count < Self.reply.count)
        #expect(!container.mainContext.hasChanges)

        // No more tokens arrive after stopping.
        let textAtStop = partial.text
        try await Task.sleep(for: .milliseconds(100))
        #expect(partial.text == textAtStop)
    }

    @Test func stopBeforeFirstTokenDropsEmptyReply() {
        let model = makeModel(tokenDelay: .seconds(10))
        model.draft = "Hello"
        model.send()
        model.stop()

        #expect(!model.isGenerating)
        #expect(model.messages.map(\.role) == [.user])
    }

    @Test func regenerateReplacesLastReply() async throws {
        let model = makeModel()
        model.draft = "Hello"
        model.send()
        await model.waitForGeneration()
        let firstReplyID = try #require(model.messages.last?.id)

        model.regenerate()
        await model.waitForGeneration()

        #expect(model.messages.count == 2)
        #expect(model.messages.last?.id != firstReplyID)
        #expect(model.messages.last?.text == Self.reply)
    }

    @Test func editAndResendReplacesLastExchange() async throws {
        let model = makeModel()
        model.draft = "Hello"
        model.send()
        await model.waitForGeneration()
        let userMessage = try #require(model.lastUserMessage)

        model.beginEditing(userMessage)
        #expect(model.draft == "Hello")
        model.draft = "Hello again"
        model.send()
        await model.waitForGeneration()

        #expect(model.editingMessage == nil)
        #expect(model.messages.map(\.text) == ["Hello again", Self.reply])
        #expect(model.messages.first?.id == userMessage.id)
    }

    @Test func onlyTheLastUserMessageCanBeEdited() async throws {
        let model = makeModel()
        model.draft = "First"
        model.send()
        await model.waitForGeneration()
        model.draft = "Second"
        model.send()
        await model.waitForGeneration()

        let first = try #require(model.messages.first)
        model.beginEditing(first)
        #expect(model.editingMessage == nil)
    }

    @Test func deletingConversationMidReplyIsSafe() async throws {
        let model = makeModel(tokenDelay: .milliseconds(20))
        model.draft = "Hello"
        model.send()
        try await waitUntil { !(model.messages.last?.text.isEmpty ?? true) }

        try store.delete(conversation)
        model.stop()

        #expect(!model.isGenerating)
        #expect(try store.conversations().isEmpty)
    }

    private static func host(_ engine: any ChatEngine) -> EngineHost {
        EngineHost(choice: .scripted) { _ in engine }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Fails its first reply immediately; later replies stream "ok".
/// Fails any reply requested from a cancelled task, so a stopped generation always ends
/// with an error, whichever generation reaches the engine first.
private final class FailsWhenCancelledEngine: ChatEngine {
    struct Failure: Error {}
    let displayName = "Fails when cancelled"
    let capabilities = EngineCapabilities(supportsVision: false, maxContextTokens: 1024)

    func load(progress: @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func reply(to turn: ChatTurn, history: [ChatTurn], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        let cancelled = Task.isCancelled
        return AsyncThrowingStream { continuation in
            if cancelled {
                continuation.finish(throwing: Failure())
            } else {
                continuation.yield(.token("ok"))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }
}

extension ChatViewModelTests {
    @Test func staleGenerationErrorDoesNotLeakIntoNewerReply() async throws {
        let model = ChatViewModel(conversation: conversation, store: store, host: Self.host(FailsWhenCancelledEngine()))
        model.draft = "Hello"
        model.send()   // generation 1: stopped before it runs, so its reply fails
        model.stop()
        model.regenerate()   // generation 2 starts before generation 1's task has run
        await model.waitForGeneration()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.errorMessage == nil)
        #expect(model.messages.map(\.text) == ["Hello", "ok"])
    }
}

@MainActor
struct StopAndContinueTests {
    private let container: ModelContainer
    private let store: ConversationStore
    private let conversation: Conversation

    init() throws {
        container = try ConversationStore.makeContainer(inMemory: true)
        store = ConversationStore(context: container.mainContext)
        conversation = try store.createConversation()
    }

    @Test func aStoppedReplyIsMarkedAndCanBeContinued() async throws {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let engine = ScriptedEngine(replies: [long, "the rest"], tokenDelay: .milliseconds(20))
        let model = ChatViewModel(conversation: conversation, store: store, host: EngineHost(choice: .scripted) { _ in engine })
        model.draft = "Hello"
        model.send()
        for _ in 0..<200 where model.messages.last?.text.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.stop()

        let reply = try #require(model.messages.last)
        #expect(reply.wasInterrupted)
        #expect(!reply.stoppedAtLengthLimit)
        #expect(model.canContinue)
        #expect(model.canRegenerate)

        let before = reply.text
        model.continueReply()
        #expect(!reply.wasInterrupted)
        await model.waitForGeneration()
        #expect(reply.text.hasPrefix(before))
        #expect(reply.text.count > before.count)
        #expect(!reply.wasInterrupted)
        #expect(!model.canContinue)
    }

    @Test func aFinishedReplyIsNotInterrupted() async {
        let engine = ScriptedEngine(replies: ["Done."], tokenDelay: .milliseconds(1))
        let model = ChatViewModel(conversation: conversation, store: store, host: EngineHost(choice: .scripted) { _ in engine })
        model.draft = "Hi"
        model.send()
        await model.waitForGeneration()
        #expect(model.messages.last?.wasInterrupted == false)
        #expect(!model.canContinue)
    }
}
