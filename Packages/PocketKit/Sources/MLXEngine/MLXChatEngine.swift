import ChatCore
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Synchronization

/// A `ChatEngine` that runs a downloaded MLX model on the GPU.
///
/// MLX needs a real Metal GPU: use this on devices and Macs, and `ScriptedEngine` in the Simulator.
///
/// **Conversation reuse.** After processing a prompt, the engine keeps a copy of the model's
/// cache at the point the next turn will start from (the end of the user's message, before the
/// template's reply header). The next reply processes only the tokens after that point when its
/// rendered prompt starts with exactly the same tokens. Anything that changes earlier text (an
/// edited or regenerated message, another conversation, a persona change, a thinking switch that
/// changes the template's output) fails that check and processes the whole prompt; unloading or
/// switching models drops the copy. This works for hybrid models such as Qwen 3.5, whose
/// recurrent layers cannot be rewound, and for templates that render earlier replies
/// differently from how the model wrote them.
///
/// Conversations with images go through MLXVLM and `ChatSession` and are processed in full.
public final class MLXChatEngine: ChatEngine {
    public enum EngineError: LocalizedError, Equatable {
        case notLoaded
        /// The vision model does not fit in the memory free now. The text model stays loaded.
        case imageNeedsMoreMemory(String)
        /// The vision model failed to load; the text model was loaded again.
        case visionModelFailed(String)
        /// Stopped because the system ran low on memory.
        case stoppedForMemory

        public var errorDescription: String? {
            switch self {
            case .notLoaded: "The model is not loaded yet."
            case .imageNeedsMoreMemory(let message): message
            case .visionModelFailed(let reason):
                "Could not load the model's image reader (\(reason)). Text chat still works."
            case .stoppedForMemory:
                "Stopped to free memory: the device was running low. Send the message again to retry."
            }
        }
    }

    /// When images may be read: the vision model's memory need and what to say when it does
    /// not fit.
    public struct ImageMemoryGuard: Sendable {
        /// Memory the vision model needs during an image turn (the catalog's measured figure).
        public var requiredBytes: Int64
        /// Shown when it does not fit, e.g. naming smaller vision models.
        public var tooLargeMessage: String
        /// Memory the process may still allocate. `nil` means unknown (macOS): no check.
        public var availableBytes: @Sendable () -> Int64?

        public init(requiredBytes: Int64, tooLargeMessage: String) {
            self.init(requiredBytes: requiredBytes, tooLargeMessage: tooLargeMessage) { ProcessMemory.availableBytes() }
        }

        init(requiredBytes: Int64, tooLargeMessage: String, availableBytes: @escaping @Sendable () -> Int64?) {
            self.requiredBytes = requiredBytes
            self.tooLargeMessage = tooLargeMessage
            self.availableBytes = availableBytes
        }

        /// Whether the vision model fits once `releasableBytes` (the text model and the MLX
        /// cache) are freed.
        func fits(releasableBytes: Int64) -> Bool {
            guard let available = availableBytes() else { return true }
            return available + releasableBytes >= requiredBytes
        }
    }

    public let displayName: String
    public let capabilities: EngineCapabilities

    private let directory: URL
    private let gpuCacheLimitBytes: Int
    private let reasoningTags: ReasoningTags
    private let reusesConversation: Bool
    private let maxKeptPrefixBytes: Int
    private let maxImageDimension: Int?
    private let imageGuard: ImageMemoryGuard?
    private let state = Mutex(State())

    private struct State {
        var container: ModelContainer?
        /// The container was loaded through MLXVLM (with the vision tower).
        var isVisionContainer = false
        /// Replies in flight, so `unload()` can stop them before freeing the model.
        var replies: [UUID: Task<Void, Never>] = [:]
        /// The cache at the start of the next turn. Taken out while a reply extends it.
        var prefix: PromptPrefix?
        /// Whether the chat template's generation prompt opens a reasoning block, per thinking
        /// setting. It depends only on the template, so it is worked out once.
        var primedInside: [Bool: Bool] = [:]
        /// Prompt processing of the latest reply. For tests.
        var lastPrompt: PromptStats?
        /// MLX active memory just before the vision model started loading. For tests.
        var activeBytesBeforeVisionLoad: Int?
        /// Bumped by `unload()`, so a model switch that finishes afterwards stores nothing.
        var epoch = 0
        /// `unload()` ran because memory was low; replies it stopped say so.
        var unloadedForMemory = false
    }

    /// How much of a prompt was processed and how much came from the kept cache.
    struct PromptStats: Sendable, Equatable {
        var prefilledTokens: Int
        var cachedTokens: Int
        var seconds: Double
    }

    /// - Parameters:
    ///   - supportsThinking: The chat template takes `enable_thinking` (see the catalog).
    ///   - supportsVision: Accept images on user turns. The model is loaded as a text model
    ///     (smaller, as measured on devices) and reloaded through MLXVLM the first time a
    ///     conversation with an image is answered.
    ///   - reasoningTags: Delimiters around the model's reasoning in its output. Reasoning is
    ///     split out with these even when thinking is off, so it never reaches the reply text.
    ///   - maxContextTokens: The context the app keeps conversations within (memory, not the
    ///     model's theoretical maximum, is the limit on phones).
    ///   - reusesConversation: Keep the cache between turns. Off only to measure the difference.
    ///   - maxKeptPrefixBytes: The kept copy of the cache doubles the cache's memory while a reply
    ///     runs. Past this size no copy is kept, and the next turn processes its prompt again.
    public init(
        directory: URL,
        displayName: String,
        supportsThinking: Bool = false,
        supportsVision: Bool = false,
        reasoningTags: ReasoningTags = .think,
        maxContextTokens: Int = 8192,
        gpuCacheLimitBytes: Int = 256 << 20,
        reusesConversation: Bool = true,
        maxKeptPrefixBytes: Int = 256 << 20,
        maxImageDimension: Int? = nil,
        imageGuard: ImageMemoryGuard? = nil
    ) {
        self.maxImageDimension = maxImageDimension
        self.imageGuard = imageGuard
        self.directory = directory
        self.displayName = displayName
        self.capabilities = EngineCapabilities(
            supportsVision: supportsVision, maxContextTokens: maxContextTokens, supportsThinking: supportsThinking)
        self.gpuCacheLimitBytes = gpuCacheLimitBytes
        self.reasoningTags = reasoningTags
        self.reusesConversation = reusesConversation
        self.maxKeptPrefixBytes = maxKeptPrefixBytes
    }

    /// Loads weights and tokenizer from disk. Reading local files reports no intermediate
    /// progress, so this reports 0 at the start and 1 when ready.
    public func load(progress: @Sendable (Double) -> Void) async throws {
        if state.withLock({ $0.container != nil }) {
            progress(1)
            return
        }
        progress(0)
        state.withLock { $0.unloadedForMemory = false }
        MLX.Memory.cacheLimit = gpuCacheLimitBytes
        // Measure this model's peak from here on (the setter resets the counter).
        MLX.Memory.peakMemory = 0
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader())
        try Task.checkCancellation()
        state.withLock {
            $0.container = container
            $0.isVisionContainer = false
        }
        progress(1)
    }

    /// The loaded container, switched to the vision model first when `vision` is needed.
    ///
    /// Phones cannot hold the text and vision models at once, so the text model is released
    /// completely before the vision model loads: nothing here keeps a reference to it.
    private func container(vision: Bool) async throws -> (ModelContainer, isVision: Bool) {
        let loaded: (ModelContainer, Bool)? = state.withLock { state in
            guard let container = state.container else { return nil }
            return vision && !state.isVisionContainer ? nil : (container, state.isVisionContainer)
        }
        if let loaded { return loaded }
        guard state.withLock({ $0.container != nil }) else { throw EngineError.notLoaded }

        if let imageGuard {
            let releasable = Int64(MLX.Memory.activeMemory + MLX.Memory.cacheMemory)
            guard imageGuard.fits(releasableBytes: releasable) else {
                throw EngineError.imageNeedsMoreMemory(imageGuard.tooLargeMessage)
            }
        }
        // Drop the text model and the kept cache: the last references, so their arrays free now.
        let epoch = state.withLock { state in
            state.container = nil
            state.prefix = nil
            return state.epoch
        }
        MLX.Memory.clearCache()
        state.withLock { $0.activeBytesBeforeVisionLoad = MLX.Memory.activeMemory }
        do {
            let visionContainer = try await VLMModelFactory.shared.loadContainer(
                from: directory, using: TransformersTokenizerLoader())
            guard store(visionContainer, isVision: true, epoch: epoch) else { throw CancellationError() }
            try Task.checkCancellation()
            return (visionContainer, true)
        } catch let error as CancellationError {
            throw error
        } catch {
            // Keep the chat working: bring the text model back (unless the engine was unloaded).
            MLX.Memory.clearCache()
            if state.withLock({ $0.epoch == epoch }),
                let text = try? await LLMModelFactory.shared.loadContainer(
                    from: directory, using: TransformersTokenizerLoader())
            {
                store(text, isVision: false, epoch: epoch)
            }
            throw EngineError.visionModelFailed(error.localizedDescription)
        }
    }

    /// Makes `container` the loaded model unless `unload()` ran since `epoch`.
    @discardableResult
    private func store(_ container: ModelContainer, isVision: Bool, epoch: Int) -> Bool {
        state.withLock { state in
            guard state.epoch == epoch else { return false }
            state.container = container
            state.isVisionContainer = isVision
            return true
        }
    }

    /// Stops any reply in flight, frees the model and its kept cache, and returns cached GPU memory.
    public func unload() async {
        await unload(forMemory: false)
    }

    /// Frees the model because the system is low on memory. A reply in flight stops and ends
    /// with `EngineError.stoppedForMemory`, so the chat says why.
    public func unloadForMemoryWarning() async {
        await unload(forMemory: true)
    }

    private func unload(forMemory: Bool) async {
        let replies = state.withLock { state in
            let replies = Array(state.replies.values)
            state.replies = [:]
            state.container = nil
            state.prefix = nil
            state.epoch += 1
            state.unloadedForMemory = forMemory && !replies.isEmpty
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
        AsyncThrowingStream { continuation in
            let initialRequest = Request(
                turn: turn, history: history, options: options,
                thinking: options.thinking && capabilities.supportsThinking,
                tags: reasoningTags,
                vision: capabilities.supportsVision)
            let id = UUID()
            let task = Task { [weak self] in
                var request = initialRequest
                do {
                    guard let self else { throw EngineError.notLoaded }
                    let container: ModelContainer
                    let isVision: Bool
                    do {
                        (container, isVision) = try await self.container(vision: request.hasImages)
                    } catch EngineError.imageNeedsMoreMemory where request.turn.images.isEmpty {
                        // Only earlier messages have images: answer from the text without them
                        // rather than failing every turn of this chat.
                        request.vision = false
                        (container, isVision) = try await self.container(vision: false)
                    }
                    let primed = try await self.promptEndsInsideReasoning(container: container, request: request)
                    var output = Output(continuation: continuation, tags: request.tags, primedInside: primed)
                    let prompt: PromptStats?
                    if isVision {
                        prompt = try await Self.generateWithSession(
                            container: container, request: request, maxImageDimension: self.maxImageDimension, output: &output)
                    } else {
                        prompt = try await self.generateReusingPrefix(container: container, request: request, output: &output)
                    }
                    self.state.withLock { $0.lastPrompt = prompt }
                    try output.finish()
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    let forMemory = self?.state.withLock { $0.unloadedForMemory } ?? false
                    continuation.finish(throwing: forMemory ? EngineError.stoppedForMemory : error)
                }
                _ = self?.state.withLock { $0.replies.removeValue(forKey: id) }
            }
            // If the reply already finished, this leaves a finished task behind until the next
            // `unload()`, which awaits it instantly. Harmless and simpler than ordering the two.
            state.withLock { $0.replies[id] = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Requests

    struct Request: Sendable {
        var turn: ChatTurn
        var history: [ChatTurn]
        var options: GenerationOptions
        var thinking: Bool
        var tags: ReasoningTags
        var vision: Bool

        var instructions: String {
            history.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        }

        /// The conversation contains images the model must see.
        var hasImages: Bool {
            vision && (!turn.images.isEmpty || history.contains { !$0.images.isEmpty })
        }

        /// Templates that know `enable_thinking` read it; others ignore it. Qwen 3.5 4B and 9B
        /// think unless it is explicitly false, so it is always passed.
        var templateContext: [String: any Sendable] {
            ["enable_thinking": thinking]
        }

        var parameters: GenerateParameters {
            GenerateParameters(maxTokens: options.maxTokens, temperature: Float(options.temperature))
        }

        /// System, history and the new message, as the template sees them.
        var messages: [Chat.Message] {
            var messages: [Chat.Message] = []
            if !instructions.isEmpty {
                messages.append(.system(instructions))
            }
            messages += history.compactMap { MLXChatEngine.chatMessage($0, vision: vision) }
            if let current = MLXChatEngine.chatMessage(turn, vision: vision) {
                messages.append(current)
            }
            return messages
        }
    }

    /// Streams text through the reasoning splitter to the caller.
    private struct Output: Sendable {
        let continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
        var splitter: ReasoningSplitter
        let clock = ContinuousClock()
        var firstChunk: ContinuousClock.Instant?
        var chunks = 0
        var hitLengthLimit = false

        init(continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation, tags: ReasoningTags, primedInside: Bool) {
            self.continuation = continuation
            self.splitter = ReasoningSplitter(start: tags.start, end: tags.end, primedInside: primedInside)
        }

        mutating func chunk(_ text: String) {
            let now = clock.now
            if firstChunk == nil { firstChunk = now }
            chunks += 1
            send(splitter.process(text))
            // Interim speed from streamed chunks; the final figure comes from MLX's own token count.
            if chunks.isMultiple(of: 8), let firstChunk {
                let seconds = (now - firstChunk) / .seconds(1)
                if seconds > 0 {
                    continuation.yield(.stats(tokensPerSecond: Double(chunks - 1) / seconds))
                }
            }
        }

        mutating func info(_ info: GenerateCompletionInfo) {
            continuation.yield(.stats(tokensPerSecond: info.tokensPerSecond))
            hitLengthLimit = info.stopReason == .length
        }

        private func send(_ segments: [ReasoningSplitter.Segment]) {
            for segment in segments {
                switch segment {
                case .reasoning(let text): continuation.yield(.reasoning(text))
                case .answer(let text): continuation.yield(.token(text))
                }
            }
        }

        mutating func finish() throws {
            send(splitter.finish())
            continuation.yield(
                .memory(
                    MemoryUsage(
                        peakBytes: Int64(MLX.Memory.peakMemory),
                        processFootprintBytes: ProcessMemory.footprintBytes())))
            if hitLengthLimit {
                continuation.yield(.lengthLimitReached)
            }
            try Task.checkCancellation()
        }
    }

    // MARK: Text: reuse the kept prefix

    /// Renders the prompt, continues from the kept cache when the prompt starts with its tokens,
    /// keeps a new copy at the point the next turn will share, then generates.
    private func generateReusingPrefix(
        container: ModelContainer, request: Request, output: inout Output
    ) async throws -> PromptStats {
        // Taken out: only one reply extends it, and a failed or cancelled one leaves none behind.
        let kept = state.withLock { state in
            let kept = state.prefix
            state.prefix = nil
            return kept
        }
        let reuse = reusesConversation
        let maxKeptBytes = maxKeptPrefixBytes
        let initialOutput = output
        let (stats, next, finalOutput) = try await container.perform { (model: ModelContext) in
            var output = initialOutput
            let messages = request.messages
            let prompt = try await model.processor.prepare(
                input: UserInput(chat: messages, additionalContext: request.templateContext))
            let tokens = prompt.text.tokens.asArray(Int.self)

            // Where the next turn's prompt will part from this one: render the same conversation
            // followed by a reply and another message, and compare. A few tokens of margin cover
            // tokenizers that merge differently next to the reply text.
            var boundary = 0
            if reuse {
                let probe = try await model.processor.prepare(
                    input: UserInput(
                        chat: messages + [.assistant("OK"), .user("OK")], additionalContext: request.templateContext))
                let probeTokens = probe.text.tokens.asArray(Int.self)
                boundary = max(PromptPrefix.commonPrefixLength(tokens, probeTokens) - 2, 0)
            }

            let start = Date.now
            var cache: [KVCache]
            var cachedCount = 0
            if let kept, kept.tokens.count <= boundary, tokens.starts(with: kept.tokens) {
                cache = kept.cache
                cachedCount = kept.tokens.count
            } else {
                cache = try model.model.newCache(parameters: request.parameters)
            }

            // Process up to the boundary and keep a copy there for the next turn.
            // The copy is skipped when the cache is past the cap: two copies of a long
            // conversation's cache would not fit next to the model on a phone.
            var next: PromptPrefix?
            if boundary > cachedCount {
                try Task.checkCancellation()
                PromptPrefix.prefill(Array(tokens[cachedCount..<boundary]), model: model.model, cache: cache)
            }
            if boundary >= cachedCount, boundary > 0,
               PromptPrefix.shouldKeep(cacheBytes: PromptPrefix.bytes(of: cache), limit: maxKeptBytes) {
                next = PromptPrefix(tokens: Array(tokens[..<boundary]), cache: cache.map { $0.copy() })
            }
            let prefillSeconds = Date.now.timeIntervalSince(start)
            let processedHere = max(boundary - cachedCount, 0)

            // Generate from the rest of the prompt.
            let rest = Array(tokens[max(boundary, cachedCount)...])
            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(rest)), cache: cache, parameters: request.parameters, context: model)
            var stats = PromptStats(prefilledTokens: processedHere, cachedTokens: cachedCount, seconds: prefillSeconds)
            for await item in stream {
                if Task.isCancelled { break }
                switch item {
                case .chunk(let text):
                    output.chunk(text)
                case .info(let info):
                    output.info(info)
                    stats.prefilledTokens += info.promptTokenCount
                    stats.seconds += info.promptTime
                case .toolCall, .rejectedToolCall:
                    break
                }
            }
            return (stats, next.map(PromptPrefixBox.init), output)
        }
        output = finalOutput
        if let next = next?.prefix {
            state.withLock { $0.prefix = next }
        }
        return stats
    }

    // MARK: Images: a fresh ChatSession

    private static func generateWithSession(
        container: ModelContainer, request: Request, maxImageDimension: Int?, output: inout Output
    ) async throws -> PromptStats? {
        let instructions = request.instructions
        let image: (URL) -> UserInput.Image = { url in
            guard let maxImageDimension else { return .url(url) }
            return ImageDownscaler.image(at: url, maxDimension: maxImageDimension)
        }
        let history: [Chat.Message] = request.history.compactMap { turn in
            switch turn.role {
            case .system: nil
            case .user: .user(turn.text, images: turn.images.map(image))
            case .assistant: .assistant(turn.text)
            }
        }
        let session: ChatSession
        if maxImageDimension != nil {
            // Images arrive already sized; the library's own resize would scale small ones up.
            session = ChatSession(
                container,
                instructions: instructions.isEmpty ? nil : instructions,
                history: history,
                generateParameters: request.parameters,
                processing: UserInput.Processing(),
                additionalContext: request.templateContext)
        } else {
            session = ChatSession(
                container,
                instructions: instructions.isEmpty ? nil : instructions,
                history: history,
                generateParameters: request.parameters,
                additionalContext: request.templateContext)
        }
        var prompt: PromptStats?
        let images = request.turn.images.map(image)
        for try await item in session.streamDetails(to: request.turn.text, images: images) {
            switch item {
            case .chunk(let text):
                output.chunk(text)
            case .info(let info):
                output.info(info)
                prompt = PromptStats(
                    prefilledTokens: info.promptTokenCount, cachedTokens: info.cachedPromptTokenCount,
                    seconds: info.promptTime)
            case .toolCall, .rejectedToolCall:
                break
            }
        }
        return prompt
    }

    // MARK: Template

    /// Whether the template ends the prompt inside a reasoning block (Qwen with thinking on
    /// ends it with `<think>`). Rendered once per thinking setting with a one-message chat: the
    /// generation prompt does not depend on the conversation.
    private func promptEndsInsideReasoning(container: ModelContainer, request: Request) async throws -> Bool {
        if let known = state.withLock({ $0.primedInside[request.thinking] }) {
            return known
        }
        let context = request.templateContext
        let tags = request.tags
        let primed = try await container.perform { (model: ModelContext) in
            let tokenizer = model.tokenizer
            let tokens = try tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Hello"]], tools: nil, additionalContext: context)
            let tail = tokenizer.decode(tokenIds: Array(tokens.suffix(32)), skipSpecialTokens: false)
            return ReasoningSplitter.promptEndsInsideReasoning(tail, start: tags.start, end: tags.end)
        }
        state.withLock { $0.primedInside[request.thinking] = primed }
        return primed
    }

    /// Images go to vision models with their turn, so a rebuilt session still sees them.
    fileprivate static func chatMessage(_ turn: ChatTurn, vision: Bool) -> Chat.Message? {
        switch turn.role {
        case .system: nil  // passed as instructions
        case .user: .user(turn.text, images: vision ? turn.images.map { .url($0) } : [])
        case .assistant: .assistant(turn.text)
        }
    }

    // MARK: Test hooks

    /// How many prompt tokens the kept cache holds, or `nil` if none is kept.
    var keptPrefixTokens: Int? {
        state.withLock { $0.prefix?.tokens.count }
    }

    /// Prompt processing of the latest reply.
    var lastPromptStats: PromptStats? {
        state.withLock { $0.lastPrompt }
    }

    /// MLX active memory just before the vision model started loading.
    var activeBytesBeforeVisionLoad: Int? {
        state.withLock { $0.activeBytesBeforeVisionLoad }
    }

    /// The container in use was loaded through MLXVLM.
    var isUsingVisionModel: Bool {
        state.withLock { $0.isVisionContainer }
    }
}

/// Prompt tokens and the model cache after processing exactly those tokens. Used by one reply
/// at a time (the engine takes it out of its state while a reply runs), hence `@unchecked`.
final class PromptPrefix: @unchecked Sendable {
    let tokens: [Int]
    let cache: [KVCache]

    init(tokens: [Int], cache: [KVCache]) {
        self.tokens = tokens
        self.cache = cache
    }

    /// Memory the cache's arrays take.
    static func bytes(of cache: [KVCache]) -> Int {
        cache.reduce(0) { total, layer in total + layer.state.reduce(0) { $0 + $1.nbytes } }
    }

    /// Whether a copy of a cache of `cacheBytes` may be kept for the next turn.
    static func shouldKeep(cacheBytes: Int, limit: Int) -> Bool {
        cacheBytes <= limit
    }

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
    }

    /// Runs `tokens` through the model into `cache`, in chunks, without sampling.
    static func prefill(_ tokens: [Int], model: any LanguageModel, cache: [KVCache], step: Int = 512) {
        var start = 0
        while start < tokens.count {
            let end = min(start + step, tokens.count)
            let chunk = MLXArray(Array(tokens[start..<end])).expandedDimensions(axis: 0)
            _ = model(LMInput.Text(tokens: chunk), cache: cache, state: nil)
            eval(cache)
            start = end
        }
    }
}

/// Carries a `PromptPrefix` out of `ModelContainer.perform`, whose result must be `Sendable`.
private struct PromptPrefixBox: Sendable {
    let prefix: PromptPrefix
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
