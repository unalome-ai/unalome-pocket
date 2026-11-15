import Foundation

/// The single boundary between the app and any inference runtime (plan section 1).
/// Feature code talks to this protocol only.
public protocol ChatEngine: Sendable {
    /// Human-readable engine or model name, shown in the status pill.
    var displayName: String { get }
    var capabilities: EngineCapabilities { get }

    func load(progress: @Sendable (Double) -> Void) async throws
    func unload() async

    /// Streams the reply to `turn`. `history` holds the earlier turns, oldest first.
    /// Cancelling the consuming task (or dropping the stream) stops generation.
    func reply(
        to turn: ChatTurn,
        history: [ChatTurn],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error>
}

public struct EngineCapabilities: Sendable, Equatable {
    public var supportsVision: Bool
    public var maxContextTokens: Int
    /// The model can reason before it answers, and that can be switched on and off per reply.
    public var supportsThinking: Bool

    public init(supportsVision: Bool, maxContextTokens: Int, supportsThinking: Bool = false) {
        self.supportsVision = supportsVision
        self.maxContextTokens = maxContextTokens
        self.supportsThinking = supportsThinking
    }
}

public enum ChatRole: String, Sendable, Codable, CaseIterable {
    case system
    case user
    case assistant
}

/// One message as the engine sees it. Value type, so it can cross into the engine safely.
public struct ChatTurn: Sendable, Equatable {
    public var role: ChatRole
    public var text: String
    /// Image files attached to this turn (user turns only). Engines without vision ignore them.
    public var images: [URL]

    public init(role: ChatRole, text: String, images: [URL] = []) {
        self.role = role
        self.text = text
        self.images = images
    }
}

public struct GenerationOptions: Sendable, Equatable {
    /// Reply length cap without thinking.
    public static let defaultMaxTokens = 1024
    /// With thinking on, the reasoning shares the cap, so it is larger.
    public static let thinkingMaxTokens = 4096

    public var temperature: Double
    public var maxTokens: Int
    /// Ask the model to reason before answering. Ignored by engines without `supportsThinking`.
    public var thinking: Bool

    public init(temperature: Double = 0.7, maxTokens: Int? = nil, thinking: Bool = false) {
        self.temperature = temperature
        self.maxTokens = maxTokens ?? (thinking ? Self.thinkingMaxTokens : Self.defaultMaxTokens)
        self.thinking = thinking
    }
}

public enum GenerationEvent: Sendable, Equatable {
    /// A piece of reply text, to be appended as-is.
    case token(String)
    /// A piece of the model's reasoning, shown apart from the reply and never sent back to it.
    case reasoning(String)
    /// Decode speed so far.
    case stats(tokensPerSecond: Double)
    /// Memory the model used for this reply, measured by the engine.
    case memory(MemoryUsage)
    /// The reply was cut off at `GenerationOptions.maxTokens`. Followed by `.done`.
    case lengthLimitReached
    /// The reply finished normally.
    case done
}

public struct MemoryUsage: Sendable, Equatable {
    /// Peak bytes the inference runtime allocated since the model loaded (weights included).
    public var peakBytes: Int64
    /// The whole process's memory footprint when the reply ended.
    public var processFootprintBytes: Int64?

    public init(peakBytes: Int64, processFootprintBytes: Int64?) {
        self.peakBytes = peakBytes
        self.processFootprintBytes = processFootprintBytes
    }
}
