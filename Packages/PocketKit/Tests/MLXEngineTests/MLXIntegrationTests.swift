import ChatCore
import Foundation
import MLX
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
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POCKETKIT_MLX_INTEGRATION"] == "1"))
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
    }

    private static func collect(
        _ engine: MLXChatEngine, _ prompt: String, history: [ChatTurn] = [], options: GenerationOptions
    ) async throws -> Reply {
        var reply = Reply()
        for try await event in engine.reply(to: ChatTurn(role: .user, text: prompt), history: history, options: options) {
            switch event {
            case .token(let token): reply.text += token
            case .reasoning(let piece): reply.reasoning += piece
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
}
