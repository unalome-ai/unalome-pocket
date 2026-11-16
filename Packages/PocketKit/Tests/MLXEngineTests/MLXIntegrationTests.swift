import ChatCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MLX
import MLXLLM
import MLXLMCommon
import ModelCatalog
import Testing
@testable import MLXEngine

/// Downloads the smallest catalog model and generates with it on this Mac's GPU.
///
/// Opt-in, because it downloads about 650 MB and needs Metal:
///
///     POCKETKIT_MLX_INTEGRATION=1 swift test --filter MLXIntegrationTests
///
/// The model is kept in `POCKETKIT_MLX_MODEL_DIR` (default: a folder in the system temp
/// directory), so later runs skip the download.
// Serialized: the tests share the GPU, and the timing test must run alone.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["POCKETKIT_MLX_INTEGRATION"] == "1"))
struct MLXIntegrationTests {
    private static let modelID = "mlx-community/Qwen3.5-0.8B-4bit"

    private static var storageRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["POCKETKIT_MLX_MODEL_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appending(path: "PocketKitMLXIntegration")
    }

    private static func installedModel() async throws -> URL {
        let storage = ModelStorage(root: storageRoot)
        if storage.isInstalled(modelID) {
            return storage.directory(for: modelID)
        }
        let entry = try #require(try CatalogLoader.bundled().models.first { $0.id == modelID })
        return try await ModelDownloader(storage: storage).download(entry) { _ in }
    }

    private struct Reply {
        var text = ""
        var reasoning = ""
        var speed: Double?
        var memory: MemoryUsage?
        var hitLimit = false
        /// Time to the first streamed text: prompt processing plus one decode step.
        var firstToken: Duration?
    }

    private static func collect(
        _ engine: MLXChatEngine, _ prompt: String, images: [URL] = [], history: [ChatTurn] = [],
        options: GenerationOptions
    ) async throws -> Reply {
        var reply = Reply()
        let start = ContinuousClock.now
        let turn = ChatTurn(role: .user, text: prompt, images: images)
        for try await event in engine.reply(to: turn, history: history, options: options) {
            switch event {
            case .token(let token):
                if reply.firstToken == nil { reply.firstToken = ContinuousClock.now - start }
                reply.text += token
            case .reasoning(let piece):
                if reply.firstToken == nil { reply.firstToken = ContinuousClock.now - start }
                reply.reasoning += piece
            case .stats(let tokensPerSecond): reply.speed = tokensPerSecond
            case .memory(let usage): reply.memory = usage
            case .lengthLimitReached: reply.hitLimit = true
            case .done: break
            }
        }
        return reply
    }

    private static func report(_ label: String, _ reply: Reply) {
        let memory = reply.memory.map {
            "peak \(ByteFormat.memory($0.peakBytes)), footprint \($0.processFootprintBytes.map(ByteFormat.memory) ?? "?")"
        } ?? "no memory report"
        print("MLX integration [\(label)]: \(String(format: "%.1f", reply.speed ?? 0)) tok/s, \(memory), hit limit: \(reply.hitLimit)")
        print("MLX integration [\(label)] reasoning (\(reply.reasoning.count) chars): \(reply.reasoning.prefix(400))")
        print("MLX integration [\(label)] reply: \(reply.text.prefix(600))")
    }

    @Test(.timeLimit(.minutes(20)))
    func streamsRepliesWithAndWithoutThinking() async throws {
        let directory = try await Self.installedModel()
        let entry = try #require(try CatalogLoader.bundled().models.first { $0.id == Self.modelID })
        #expect(entry.supportsThinking)
        let engine = MLXChatEngine(directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true)
        try await engine.load { _ in }

        // Thinking off (the default): a greeting gets a plain answer, no reasoning.
        let plain = try await Self.collect(engine, "Hello", options: GenerationOptions(temperature: 0.2))
        Self.report("thinking off", plain)
        #expect(plain.reasoning.isEmpty)
        #expect(!plain.text.isEmpty)
        #expect(!plain.text.contains("<think>") && !plain.text.contains("</think>"))
        #expect(!plain.text.localizedCaseInsensitiveContains("thinking process"))
        #expect((plain.speed ?? 0) > 0)
        #expect((plain.memory?.peakBytes ?? 0) > 0)

        // Thinking on: reasoning and answer arrive separately.
        let thoughtful = try await Self.collect(
            engine, "What is 17 + 25? Answer with the number.", options: GenerationOptions(temperature: 0.2, thinking: true))
        Self.report("thinking on", thoughtful)
        #expect(!thoughtful.reasoning.isEmpty)
        #expect(!thoughtful.reasoning.contains("<think>") && !thoughtful.reasoning.contains("</think>"))
        #expect(!thoughtful.text.contains("</think>"))
        if !thoughtful.hitLimit {
            #expect(thoughtful.text.contains("42"))
        }

        // A tiny cap reports the length limit.
        let capped = try await Self.collect(
            engine, "Count from 1 to 100.", options: GenerationOptions(temperature: 0.2, maxTokens: 8))
        Self.report("cap 8", capped)
        #expect(capped.hitLimit)

        // Cancelling the consumer stops generation.
        let stream = engine.reply(
            to: ChatTurn(role: .user, text: "Count from 1 to 500."), history: [],
            options: GenerationOptions(temperature: 0.2))
        var tokens = 0
        for try await event in stream {
            if case .token = event { tokens += 1 }
            if tokens == 5 { break }
        }
        #expect(tokens == 5)

        await engine.unload()
    }

    /// The same five-turn conversation with and without keeping the session. Reports the time
    /// to first token of every turn; on turn 5 only the new message should need processing.
    @Test(.timeLimit(.minutes(20)))
    func keepsTheConversationBetweenTurns() async throws {
        let directory = try await Self.installedModel()
        let system = ChatTurn(
            role: .system,
            text: "You are a helpful assistant running entirely on the user's device. Answer clearly and directly.")
        // A fixed conversation, so both runs see exactly the same prompts: the model's replies
        // are measured but the scripted answers go into the history.
        let questions = [
            "Give me five facts about the Moon, one paragraph each.",
            "Now five facts about Mars, in the same style.",
            "Compare the two in detail: which is easier to visit and why?",
            "List the planets of the Solar System with two details each.",
            "Which of the facts you gave about the Moon is the most surprising? One sentence.",
        ]
        let answers = [
            Self.scriptedAnswer(topic: "the Moon", facts: [
                "The Moon is about 384,400 kilometres from Earth on average, and it drifts away by roughly 3.8 centimetres a year.",
                "It is tidally locked, so the same side always faces Earth while the far side stays out of view.",
                "Its surface gravity is about one sixth of Earth's, which is why astronauts could bound across it.",
                "The dark plains, called maria, are ancient lava flows that cooled more than three billion years ago.",
                "Twelve people walked on the Moon between 1969 and 1972 during the Apollo programme.",
            ]),
            Self.scriptedAnswer(topic: "Mars", facts: [
                "Mars has the tallest known volcano in the Solar System, Olympus Mons, about three times the height of Everest.",
                "A Martian day, or sol, lasts 24 hours and 39 minutes, very close to a day on Earth.",
                "Its red colour comes from iron oxide, essentially rust, in the dust that covers the surface.",
                "Mars has two small moons, Phobos and Deimos, which may be captured asteroids.",
                "Its thin atmosphere is mostly carbon dioxide, and surface pressure is less than one percent of Earth's.",
            ]),
            """
            The Moon is far easier to visit. A trip takes about three days rather than six to nine months,             launch windows open every day instead of every 26 months, and radio messages arrive in just over             a second rather than up to twenty minutes. Mars offers more resources, such as water ice and an             atmosphere that can be turned into fuel, but the journey, landing and return are much harder.             For a first step beyond Earth orbit, the Moon wins on distance, time and safety.
            """,
            """
            Mercury: closest to the Sun; a year lasts 88 days. Venus: hottest surface; spins backwards.             Earth: liquid water on the surface; one large moon. Mars: red dust of iron oxide; two small moons.             Jupiter: largest planet; the Great Red Spot is a storm wider than Earth. Saturn: bright rings of ice;             lower density than water. Uranus: tilted on its side; faint rings. Neptune: strongest winds measured;             discovered by mathematics before it was seen.
            """,
        ]
        let options = GenerationOptions(temperature: 0, maxTokens: 120)

        var timings: [Bool: [Duration]] = [:]
        var prefill: [Bool: MLXChatEngine.PromptStats] = [:]
        var finalAnswers: [Bool: String] = [:]
        for reuse in [false, true] {
            let engine = MLXChatEngine(
                directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true, reusesConversation: reuse)
            try await engine.load { _ in }
            // Warm up the GPU kernels so turn 1 is comparable between the runs.
            _ = try await Self.collect(engine, "Hi", options: GenerationOptions(temperature: 0, maxTokens: 4))

            var history = [system]
            var times: [Duration] = []
            var prompts: [MLXChatEngine.PromptStats] = []
            for question in questions {
                let reply = try await Self.collect(engine, question, history: history, options: options)
                times.append(reply.firstToken ?? .zero)
                prompts.append(try #require(engine.lastPromptStats))
                let index = history.count / 2
                let answer = index < answers.count ? answers[index] : reply.text
                history += [ChatTurn(role: .user, text: question), ChatTurn(role: .assistant, text: answer)]
                // The kept cache ends inside the prompt it was made from, whatever the reply did.
                if reuse {
                    let kept = try #require(engine.keptPrefixTokens)
                    let last = try #require(prompts.last)
                    #expect(kept <= last.prefilledTokens + last.cachedTokens)
                } else {
                    #expect(engine.keptPrefixTokens == nil)
                }
                finalAnswers[reuse] = reply.text
            }
            timings[reuse] = times
            let tokens = history.map(ContextWindow.estimatedTokens).reduce(0, +)
            print("MLX integration [reuse \(reuse ? "on " : "off")]: time to first token per turn: "
                + times.map { String(format: "%.0f ms", $0 / .milliseconds(1)) }.joined(separator: ", ")
                + " (conversation ≈ \(tokens) tokens)")
            print("MLX integration [reuse \(reuse ? "on " : "off")]: prompt tokens prefilled / from cache per turn: "
                + prompts.map { "\($0.prefilledTokens)/\($0.cachedTokens) in \(String(format: "%.0f ms", $0.seconds * 1000))" }
                    .joined(separator: ", "))
            let turnFive = try #require(prompts.last)
            if reuse {
                #expect(turnFive.cachedTokens > 0, "turn 5 continues from the kept cache")
                #expect(turnFive.prefilledTokens < turnFive.cachedTokens)
            } else {
                #expect(prompts.allSatisfy { $0.cachedTokens == 0 })
            }
            prefill[reuse] = turnFive

            if reuse {
                // Editing the last message: the kept cache (which includes the old message) does
                // not match, so the whole prompt is processed, and a new copy is kept.
                let edited = Array(history.dropLast(2))
                _ = try await Self.collect(
                    engine, "Answer in one word: is the Moon bigger than Mars?", history: edited, options: options)
                #expect(engine.lastPromptStats?.cachedTokens == 0)
                #expect(engine.keptPrefixTokens != nil)

                // Another persona (system prompt) changes the very first tokens.
                var otherPersona = history
                otherPersona[0] = ChatTurn(role: .system, text: "You are a careful editor.")
                _ = try await Self.collect(engine, "Thanks!", history: otherPersona, options: options)
                #expect(engine.lastPromptStats?.cachedTokens == 0)

                await engine.unload()
                #expect(engine.keptPrefixTokens == nil, "unload drops the kept cache")
            } else {
                await engine.unload()
            }
        }
        let off = try #require(timings[false]?.last)
        let on = try #require(timings[true]?.last)
        print(String(format: "MLX integration: turn 5 time to first token %.0f ms without reuse, %.0f ms with reuse",
                     off / .milliseconds(1), on / .milliseconds(1)))
        print("MLX integration [turn 5, reuse off] \(finalAnswers[false]?.prefix(200) ?? "")")
        print("MLX integration [turn 5, reuse on ] \(finalAnswers[true]?.prefix(200) ?? "")")
        // Same prompt, greedy decoding: the answers start the same. (Processing the prompt in two
        // parts can round differently in the last bits, so long answers may drift apart later;
        // `splitPrefillMatchesSinglePass` checks the numbers directly.)
        #expect(finalAnswers[true]?.prefix(40) == finalAnswers[false]?.prefix(40))
        // Wall-clock time is noisy at these sizes on a Mac; what was prefilled is not.
        #expect(try #require(prefill[true]).prefilledTokens < (try #require(prefill[false]).prefilledTokens))
        print("MLX integration: time to first token, turn 5 (milliseconds): off \(Int(off / .milliseconds(1))), on \(Int(on / .milliseconds(1)))")
    }

    /// Loads the model through MLXVLM when an image arrives and asks about a generated picture.
    @Test(.timeLimit(.minutes(20)))
    func answersAboutAnImage() async throws {
        let directory = try await Self.installedModel()
        let entry = try #require(try CatalogLoader.bundled().models.first { $0.id == Self.modelID })
        #expect(entry.supportsVision)
        // MLX keeps some global state from earlier tests in this process; measure from here.
        MLX.Memory.clearCache()
        let baseline = MLX.Memory.activeMemory
        let engine = MLXChatEngine(
            directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true, supportsVision: true)
        try await engine.load { _ in }

        let text = try await Self.collect(engine, "Say hello in three words.", options: GenerationOptions(temperature: 0))
        Self.report("vision model, text only", text)
        #expect(!engine.isUsingVisionModel, "text-only chats stay on the text model")
        let textModelBytes = MLX.Memory.activeMemory - baseline

        let image = try Self.testImage()
        let question = "What is in this picture? Name the shape and its colour, and the background colour."
        let answer = try await Self.collect(
            engine, question, images: [image], options: GenerationOptions(temperature: 0, maxTokens: 200))
        Self.report("image", answer)
        #expect(engine.isUsingVisionModel)
        // The text model was released before the vision model loaded: phones cannot hold both.
        let beforeVisionLoad = try #require(engine.activeBytesBeforeVisionLoad) - baseline
        print("MLX integration [image]: text model \(textModelBytes >> 20) MB, active before the vision load \(beforeVisionLoad >> 20) MB")
        #expect(beforeVisionLoad < textModelBytes / 4)
        #expect(!answer.text.isEmpty)
        #expect(answer.text.localizedCaseInsensitiveContains("red"))

        // A follow-up without a new image still sees the earlier one through the kept session.
        let followUp = try await Self.collect(
            engine, "Is the shape round or square? One word.",
            history: [ChatTurn(role: .user, text: question, images: [image]), ChatTurn(role: .assistant, text: answer.text)],
            options: GenerationOptions(temperature: 0, maxTokens: 20))
        Self.report("image follow-up", followUp)
        await engine.unload()
    }

    /// When the vision model does not fit, an image fails with the guard's message and the text
    /// model stays loaded; a chat whose earlier messages have images is answered from the text.
    @Test(.timeLimit(.minutes(10)))
    func refusesImagesWhenTheVisionModelDoesNotFit() async throws {
        let directory = try await Self.installedModel()
        let message = "This model needs more memory than this device has free to read images. Try Qwen 3.5 2B."
        let engine = MLXChatEngine(
            directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true, supportsVision: true,
            imageGuard: MLXChatEngine.ImageMemoryGuard(requiredBytes: 64 << 30, tooLargeMessage: message) { 1 << 30 })
        try await engine.load { _ in }
        let image = try Self.testImage()
        await #expect(throws: MLXChatEngine.EngineError.imageNeedsMoreMemory(message)) {
            _ = try await Self.collect(engine, "What is this?", images: [image], options: GenerationOptions(temperature: 0, maxTokens: 20))
        }
        #expect(MLXChatEngine.EngineError.imageNeedsMoreMemory(message).localizedDescription == message)
        #expect(!engine.isUsingVisionModel)

        let followUp = try await Self.collect(
            engine, "Say hello in three words.",
            history: [ChatTurn(role: .user, text: "What is this?", images: [image]), ChatTurn(role: .assistant, text: "A red circle.")],
            options: GenerationOptions(temperature: 0, maxTokens: 20))
        #expect(!followUp.text.isEmpty)
        #expect(!engine.isUsingVisionModel)
        await engine.unload()
    }

    /// Past the cap, no copy of the cache is kept, so cache memory is not doubled.
    @Test(.timeLimit(.minutes(10)))
    func keptPrefixRespectsTheByteCap() async throws {
        let directory = try await Self.installedModel()
        let capped = MLXChatEngine(
            directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true, maxKeptPrefixBytes: 1)
        try await capped.load { _ in }
        _ = try await Self.collect(capped, "Say hello in three words.", options: GenerationOptions(temperature: 0, maxTokens: 10))
        #expect(capped.keptPrefixTokens == nil)
        await capped.unload()

        let uncapped = MLXChatEngine(directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true)
        try await uncapped.load { _ in }
        _ = try await Self.collect(uncapped, "Say hello in three words.", options: GenerationOptions(temperature: 0, maxTokens: 10))
        #expect((uncapped.keptPrefixTokens ?? 0) > 0)
        await uncapped.unload()
    }

    /// A memory warning during a reply stops it with an error that says why.
    @Test(.timeLimit(.minutes(10)))
    func memoryWarningStopsTheReplyWithAReason() async throws {
        let directory = try await Self.installedModel()
        let engine = MLXChatEngine(directory: directory, displayName: "Qwen 3.5 0.8B", supportsThinking: true)
        try await engine.load { _ in }
        let stream = engine.reply(
            to: ChatTurn(role: .user, text: "Count from 1 to 500."), history: [],
            options: GenerationOptions(temperature: 0))
        var tokens = 0
        var stopError: (any Error)?
        var warned = false
        do {
            for try await event in stream {
                if case .token = event { tokens += 1 }
                if tokens >= 3, !warned {
                    warned = true
                    Task { await engine.unloadForMemoryWarning() }
                }
            }
        } catch {
            stopError = error
        }
        #expect(stopError as? MLXChatEngine.EngineError == .stoppedForMemory)
        // The next load starts clean: replies are not reported as memory stops.
        try await engine.load { _ in }
        let after = try await Self.collect(engine, "Hi", options: GenerationOptions(temperature: 0, maxTokens: 4))
        #expect(!after.text.isEmpty)
        await engine.unload()
    }

    /// A red circle on a white background, 512 × 512, written to the temp directory.
    private static func testImage() throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.setFillColor(CGColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1))
        context.fillEllipse(in: CGRect(x: 106, y: 106, width: 300, height: 300))
        let url = FileManager.default.temporaryDirectory.appending(path: "pocketkit-red-circle.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func scriptedAnswer(topic: String, facts: [String]) -> String {
        "Here are five facts about \(topic).\n\n" + facts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }

    /// Processing a prompt in two parts, with a copy of the cache taken between them (what the
    /// engine does to keep a conversation), gives the same next-token prediction as one pass.
    @Test(.timeLimit(.minutes(10)))
    func splitPrefillMatchesSinglePass() async throws {
        let directory = try await Self.installedModel()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader())
        let (maxDifference, sameArgmax, tokenCount) = try await container.perform { (model: ModelContext) in
            let input = try await model.processor.prepare(
                input: UserInput(chat: [
                    .system("You are a helpful assistant."),
                    .user("Give me three facts about the Moon."),
                    .assistant("It is tidally locked. It has no air. It shapes our tides."),
                    .user("Which one matters most for life on Earth? Explain in detail, with examples, why."),
                ], additionalContext: ["enable_thinking": false]))
            let tokens = input.text.tokens.asArray(Int.self)
            let split = tokens.count * 2 / 3

            let single = try model.model.newCache(parameters: nil)
            PromptPrefix.prefill(Array(tokens.dropLast()), model: model.model, cache: single)
            let a = model.model(LMInput.Text(tokens: MLXArray([tokens.last!]).expandedDimensions(axis: 0)), cache: single, state: nil).logits

            let first = try model.model.newCache(parameters: nil)
            PromptPrefix.prefill(Array(tokens[..<split]), model: model.model, cache: first)
            let kept = first.map { $0.copy() }
            PromptPrefix.prefill(Array(tokens[split..<(tokens.count - 1)]), model: model.model, cache: kept)
            let b = model.model(LMInput.Text(tokens: MLXArray([tokens.last!]).expandedDimensions(axis: 0)), cache: kept, state: nil).logits

            let difference = abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
            let argmaxA = argMax(a[0, -1], axis: -1).item(Int.self)
            let argmaxB = argMax(b[0, -1], axis: -1).item(Int.self)
            return (difference, argmaxA == argmaxB, tokens.count)
        }
        print("MLX integration [split prefill]: \(tokenCount) tokens, largest logit difference \(maxDifference), same next token: \(sameArgmax)")
        #expect(sameArgmax)
        #expect(maxDifference < 0.5)
    }
}
