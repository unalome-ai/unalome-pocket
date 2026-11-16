import Testing
@testable import ChatCore

struct ScriptedEngineTests {
    private let script = "Hello **there**, this is\na scripted reply."
    private let turn = ChatTurn(role: .user, text: "Hi")

    @Test func tokenizeKeepsTextIntact() {
        let tokens = ScriptedEngine.tokenize(script)
        #expect(tokens.joined() == script)
        #expect(tokens.first == "Hello ")
        #expect(tokens.count == 7)
    }

    @Test func streamsWholeReplyThenStatsAndDone() async throws {
        let engine = ScriptedEngine(replies: [script], tokenDelay: .milliseconds(1))
        var text = ""
        var events: [GenerationEvent] = []
        for try await event in engine.reply(to: turn, history: [], options: GenerationOptions()) {
            events.append(event)
            if case .token(let token) = event { text += token }
        }
        #expect(text == script)
        #expect(events.last == .done)
        guard case .stats(let rate) = events.dropLast().last else {
            Issue.record("Expected stats before done, got \(events.suffix(2))")
            return
        }
        #expect(rate > 0)
    }

    @Test func honoursMaxTokens() async throws {
        let engine = ScriptedEngine(replies: [script], tokenDelay: .milliseconds(1))
        var tokens = 0
        var events: [GenerationEvent] = []
        for try await event in engine.reply(to: turn, history: [], options: GenerationOptions(maxTokens: 3)) {
            if case .token = event { tokens += 1 }
            events.append(event)
        }
        #expect(tokens == 3)
        #expect(events.suffix(2) == [.lengthLimitReached, .done])
    }

    @Test func thinkingStreamsReasoningApartFromTheReply() async throws {
        let engine = ScriptedEngine(replies: ["The answer."], tokenDelay: .zero)
        var reasoning = ""
        var text = ""
        for try await event in engine.reply(to: turn, history: [], options: GenerationOptions(thinking: true)) {
            switch event {
            case .reasoning(let piece): reasoning += piece
            case .token(let piece): text += piece
            default: break
            }
        }
        #expect(text == "The answer.")
        #expect(reasoning.hasPrefix("The user asks"))
        #expect(!text.contains("<think>") && !reasoning.contains("think>"))
        #expect(engine.capabilities.supportsThinking)
    }

    @Test func thinkingRaisesTheDefaultLengthCap() {
        #expect(GenerationOptions().maxTokens == GenerationOptions.defaultMaxTokens)
        #expect(GenerationOptions(thinking: true).maxTokens == GenerationOptions.thinkingMaxTokens)
        #expect(GenerationOptions(maxTokens: 7, thinking: true).maxTokens == 7)
    }

    @Test func picksReplyByNumberOfEarlierUserTurns() async throws {
        let engine = ScriptedEngine(replies: ["first", "second"], tokenDelay: .zero)
        let history = [ChatTurn(role: .user, text: "a"), ChatTurn(role: .assistant, text: "first")]
        var text = ""
        for try await event in engine.reply(to: turn, history: history, options: GenerationOptions()) {
            if case .token(let token) = event { text += token }
        }
        #expect(text == "second")
    }

    @Test func cancellingTheConsumerStopsTheStream() async throws {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let engine = ScriptedEngine(replies: [long], tokenDelay: .milliseconds(5))
        let stream = engine.reply(to: turn, history: [], options: GenerationOptions())

        let consumer = Task {
            var tokens = 0
            var sawDone = false
            for try await event in stream {
                switch event {
                case .token: tokens += 1
                case .done: sawDone = true
                default: break
                }
            }
            return (tokens, sawDone)
        }
        try await Task.sleep(for: .milliseconds(60))
        consumer.cancel()
        let (tokens, sawDone) = try await consumer.value

        #expect(tokens > 0)
        #expect(tokens < 200)
        #expect(!sawDone)
    }

    @Test func loadReportsCompletion() async throws {
        let engine = ScriptedEngine()
        let reported = Box()
        try await engine.load { reported.value = $0 }
        #expect(reported.value == 1)
    }
}

/// Captures a value from a `@Sendable` callback in a test.
private final class Box: @unchecked Sendable {
    var value: Double?
}

struct ScriptedResponderTests {
    @Test func answersAMatchedPromptWithItsReplyAndReasoning() async throws {
        let engine = ScriptedEngine(tokenDelay: .milliseconds(1), displayName: "Qwen 3.5 2B") { prompt in
            prompt == "Question" ? ("The **answer**.", "Some thought.") : nil
        }
        #expect(engine.displayName == "Qwen 3.5 2B")
        var text = ""
        var reasoning = ""
        let turn = ChatTurn(role: .user, text: "Question")
        for try await event in engine.reply(to: turn, history: [], options: GenerationOptions(thinking: true)) {
            if case .token(let token) = event { text += token }
            if case .reasoning(let thought) = event { reasoning += thought }
        }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "The **answer**.")
        #expect(reasoning.contains("Some thought."))
    }

    @Test func otherPromptsUseTheDefaultReplies() async throws {
        let engine = ScriptedEngine(replies: ["Default."], tokenDelay: .milliseconds(1)) { _ in nil }
        var text = ""
        for try await event in engine.reply(to: ChatTurn(role: .user, text: "Else"), history: [], options: GenerationOptions()) {
            if case .token(let token) = event { text += token }
        }
        #expect(text == "Default.")
        #expect(engine.displayName == "Scripted demo")
    }
}
