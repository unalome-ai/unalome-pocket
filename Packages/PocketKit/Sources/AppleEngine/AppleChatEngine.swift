import ChatCore
import Foundation
import FoundationModels
import ModelCatalog

/// A `ChatEngine` on Apple's built-in on-device model (`SystemLanguageModel`).
/// Nothing to download; available on Apple Intelligence devices with it turned on.
public struct AppleChatEngine: ChatEngine {
    public enum EngineError: LocalizedError {
        case unavailable(AppleModelAvailability)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let availability): availability.explanation
            }
        }
    }

    public let displayName = "Apple on-device model"
    public var capabilities: EngineCapabilities {
        EngineCapabilities(supportsVision: false, maxContextTokens: SystemLanguageModel.default.contextSize)
    }

    public init() {}

    public static var availability: AppleModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .deviceNotEligible
        }
    }

    /// The system manages the model's memory; loading only checks it can be used.
    public func load(progress: @Sendable (Double) -> Void) async throws {
        let availability = Self.availability
        guard availability.isAvailable else { throw EngineError.unavailable(availability) }
        progress(1)
    }

    public func unload() async {}

    public func reply(
        to turn: ChatTurn,
        history: [ChatTurn],
        options: ChatCore.GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(transcript: Self.transcript(from: history))
                    let generationOptions = FoundationModels.GenerationOptions(
                        temperature: options.temperature,
                        maximumResponseTokens: options.maxTokens)
                    let clock = ContinuousClock()
                    let start = clock.now
                    var text = ""
                    // Each snapshot holds the whole reply so far; pass on only the new part.
                    for try await snapshot in session.streamResponse(to: turn.text, options: generationOptions) {
                        let full = snapshot.content
                        if full.hasPrefix(text) {
                            let delta = String(full.dropFirst(text.count))
                            if !delta.isEmpty { continuation.yield(.token(delta)) }
                        } else {
                            // The model revised earlier text; rare, and appending keeps the stream simple.
                            continuation.yield(.token(full))
                        }
                        text = full
                    }
                    let seconds = (clock.now - start) / .seconds(1)
                    if seconds > 0 {
                        let tokens = try await Self.tokenCount(of: text)
                        continuation.yield(.stats(tokensPerSecond: Double(tokens) / seconds))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Exact count where the OS can tell (26.4+); otherwise about 4 characters per token.
    private static func tokenCount(of text: String) async throws -> Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            return try await SystemLanguageModel.default.tokenCount(for: Prompt(text))
        }
        return max(text.count / 4, 1)
    }

    private static func transcript(from history: [ChatTurn]) -> Transcript {
        let entries: [Transcript.Entry] = history.map { turn in
            let segments = [Transcript.Segment.text(Transcript.TextSegment(content: turn.text))]
            switch turn.role {
            case .system:
                return .instructions(Transcript.Instructions(segments: segments, toolDefinitions: []))
            case .user:
                return .prompt(Transcript.Prompt(segments: segments))
            case .assistant:
                return .response(Transcript.Response(assetIDs: [], segments: segments))
            }
        }
        return Transcript(entries: entries)
    }
}
