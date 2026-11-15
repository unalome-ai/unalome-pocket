import ChatCore
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Synchronization

/// A `ChatEngine` that runs a downloaded MLX model on the GPU.
///
/// MLX needs a real Metal GPU: use this on devices and Macs, and `ScriptedEngine` in the Simulator.
public final class MLXChatEngine: ChatEngine {
    public enum EngineError: LocalizedError {
        case notLoaded

        public var errorDescription: String? {
            "The model is not loaded yet."
        }
    }

    public let displayName: String
    public let capabilities: EngineCapabilities

    private let directory: URL
    private let gpuCacheLimitBytes: Int
    private let reasoningTags: ReasoningTags
    private let state = Mutex(State())

    private struct State {
        var container: ModelContainer?
        /// Replies in flight, so `unload()` can stop them before freeing the model.
        var replies: [UUID: Task<Void, Never>] = [:]
    }

    /// - Parameters:
    ///   - directory: Folder with `config.json`, weights and tokenizer files.
    ///   - gpuCacheLimitBytes: Cap on MLX's buffer cache. Freed buffers above this are returned
    ///     to the system instead of kept for reuse, which keeps the peak lower on phones.
    ///   - supportsThinking: The chat template takes `enable_thinking` (see the catalog).
    ///   - reasoningTags: Delimiters around the model's reasoning in its output. Reasoning is
    ///     split out with these even when thinking is off, so it never reaches the reply text.
    public init(
        directory: URL,
        displayName: String,
        supportsThinking: Bool = false,
        reasoningTags: ReasoningTags = .think,
        maxContextTokens: Int = 8192,
        gpuCacheLimitBytes: Int = 256 << 20
    ) {
        self.directory = directory
        self.displayName = displayName
        self.capabilities = EngineCapabilities(
            supportsVision: false, maxContextTokens: maxContextTokens, supportsThinking: supportsThinking)
        self.gpuCacheLimitBytes = gpuCacheLimitBytes
        self.reasoningTags = reasoningTags
    }

    /// Loads weights and tokenizer from disk. Reading local files reports no intermediate
    /// progress, so this reports 0 at the start and 1 when ready.
    public func load(progress: @Sendable (Double) -> Void) async throws {
        if state.withLock({ $0.container != nil }) {
            progress(1)
            return
        }
        progress(0)
        MLX.Memory.cacheLimit = gpuCacheLimitBytes
        // Measure this model's peak from here on (the setter resets the counter).
        MLX.Memory.peakMemory = 0
        // Text only for now: LLMModelFactory loads the language part of vision models too.
        // Image input will load vision-capable models through MLXVLM's factory instead.
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader())
        try Task.checkCancellation()
        state.withLock { $0.container = container }
        progress(1)
    }

    /// Stops any reply in flight, frees the model and returns cached GPU memory.
    public func unload() async {
        let replies = state.withLock { state in
            let replies = Array(state.replies.values)
            state.replies = [:]
            state.container = nil
            return replies
        }
        for reply in replies {
            reply.cancel()
        }
        for reply in replies {
            await reply.value
        }
        MLX.Memory.clearCache()
    }

    public func reply(
        to turn: ChatTurn,
        history: [ChatTurn],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        let container = state.withLock { $0.container }
        return AsyncThrowingStream { continuation in
            guard let container else {
                continuation.finish(throwing: EngineError.notLoaded)
                return
            }
            let id = UUID()
            let thinking = options.thinking && capabilities.supportsThinking
            let tags = reasoningTags
            let task = Task { [weak self] in
                do {
                    try await Self.generate(
                        container: container, turn: turn, history: history, options: options,
                        thinking: thinking, tags: tags, continuation: continuation)
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self?.state.withLock { _ = $0.replies.removeValue(forKey: id) }
            }
            // If the reply already finished, this leaves a finished task behind until the next
            // `unload()`, which awaits it instantly. Harmless and simpler than ordering the two.
            state.withLock { $0.replies[id] = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func generate(
        container: ModelContainer,
        turn: ChatTurn,
        history: [ChatTurn],
        options: GenerationOptions,
        thinking: Bool,
        tags: ReasoningTags,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let instructions = history.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let chatHistory = history.compactMap(Self.chatMessage)
        // Templates that know `enable_thinking` read it; others ignore it. Qwen 3.5 4B and 9B
        // think unless it is explicitly false, so it is always passed.
        let templateContext: [String: any Sendable] = ["enable_thinking": thinking]
        let primedInside = try await promptEndsInsideReasoning(
            container: container, instructions: instructions, history: chatHistory, turn: turn,
            context: templateContext, tags: tags)

        let session = ChatSession(
            container,
            instructions: instructions.isEmpty ? nil : instructions,
            history: chatHistory,
            generateParameters: GenerateParameters(
                maxTokens: options.maxTokens,
                temperature: Float(options.temperature)
            ),
            additionalContext: templateContext
        )

        var splitter = ReasoningSplitter(start: tags.start, end: tags.end, primedInside: primedInside)
        func send(_ segments: [ReasoningSplitter.Segment]) {
            for segment in segments {
                switch segment {
                case .reasoning(let text): continuation.yield(.reasoning(text))
                case .answer(let text): continuation.yield(.token(text))
                }
            }
        }

        // Interim speed from streamed chunks; the final figure comes from MLX's own token count.
        let clock = ContinuousClock()
        var firstChunk: ContinuousClock.Instant?
        var chunks = 0
        var hitLengthLimit = false
        for try await item in session.streamDetails(to: turn.text) {
            switch item {
            case .chunk(let text):
                let now = clock.now
                if firstChunk == nil { firstChunk = now }
                chunks += 1
                send(splitter.process(text))
                if chunks.isMultiple(of: 8), let firstChunk {
                    let seconds = (now - firstChunk) / .seconds(1)
                    if seconds > 0 {
                        continuation.yield(.stats(tokensPerSecond: Double(chunks - 1) / seconds))
                    }
                }
            case .info(let info):
                continuation.yield(.stats(tokensPerSecond: info.tokensPerSecond))
                hitLengthLimit = info.stopReason == .length
            case .toolCall, .rejectedToolCall:
                break
            }
        }
        send(splitter.finish())
        continuation.yield(
            .memory(
                MemoryUsage(
                    peakBytes: Int64(MLX.Memory.peakMemory),
                    processFootprintBytes: ProcessMemory.footprintBytes())))
        if hitLengthLimit {
            continuation.yield(.lengthLimitReached)
        }
    }

    /// Renders the prompt the way `ChatSession` will and checks whether the template left a
    /// reasoning block open (Qwen with thinking on ends the prompt with `<think>`).
    private static func promptEndsInsideReasoning(
        container: ModelContainer,
        instructions: String,
        history: [Chat.Message],
        turn: ChatTurn,
        context: [String: any Sendable],
        tags: ReasoningTags
    ) async throws -> Bool {
        var messages: [[String: any Sendable]] = []
        if !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        for message in history {
            messages.append(["role": message.role.rawValue, "content": message.content])
        }
        messages.append(["role": "user", "content": turn.text])
        let rendered = messages
        return try await container.perform { (model: ModelContext) in
            let tokenizer = model.tokenizer
            let tokens = try tokenizer.applyChatTemplate(
                messages: rendered, tools: nil, additionalContext: context)
            let tail = tokenizer.decode(tokenIds: Array(tokens.suffix(32)), skipSpecialTokens: false)
            return ReasoningSplitter.promptEndsInsideReasoning(tail, start: tags.start, end: tags.end)
        }
    }

    private static func chatMessage(_ turn: ChatTurn) -> Chat.Message? {
        switch turn.role {
        case .system: nil  // passed as instructions
        case .user: .user(turn.text)
        case .assistant: .assistant(turn.text)
        }
    }
}

/// Delimiters a model puts around its reasoning.
public struct ReasoningTags: Sendable, Equatable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }

    /// Qwen and most open reasoning models.
    public static let think = ReasoningTags(start: "<think>", end: "</think>")
}
