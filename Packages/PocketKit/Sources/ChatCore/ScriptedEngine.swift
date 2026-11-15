import Foundation

/// A fake engine that streams canned replies word by word.
/// Used in the Simulator, in previews and in tests, where MLX cannot run.
public struct ScriptedEngine: ChatEngine {
    public let displayName = "Scripted demo"
    public let capabilities = EngineCapabilities(supportsVision: false, maxContextTokens: 4096, supportsThinking: true)

    private let replies: [String]
    private let tokenDelay: Duration

    /// - Parameters:
    ///   - replies: Canned replies, used in turn. An empty list uses the defaults.
    ///   - tokenDelay: Pause before each token. The default gives roughly 28 tok/s.
    public init(replies: [String] = ScriptedEngine.defaultReplies, tokenDelay: Duration = .milliseconds(35)) {
        self.replies = replies.isEmpty ? ScriptedEngine.defaultReplies : replies
        self.tokenDelay = tokenDelay
    }

    public func load(progress: @Sendable (Double) -> Void) async throws {
        progress(1)
    }

    public func unload() async {}

    public func reply(
        to turn: ChatTurn,
        history: [ChatTurn],
        options: GenerationOptions
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        // Earlier user turns pick the reply, so a conversation walks through the script
        // and regenerating the same turn is deterministic.
        let userTurnsBefore = history.count { $0.role == .user }
        var script = replies[userTurnsBefore % replies.count]
        if options.thinking {
            // Like a reasoning model: thoughts in <think> tags, split out as they stream.
            script = "<think>\n\(Self.reasoning)\n</think>\n\n" + script
        }
        let allTokens = Self.tokenize(script)
        let tokens = Array(allTokens.prefix(max(options.maxTokens, 0)))
        let hitLimit = tokens.count < allTokens.count
        let delay = tokenDelay

        return AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                var emitted = 0
                func tokensPerSecond() -> Double {
                    let elapsed = (clock.now - start) / .seconds(1)
                    return elapsed > 0 ? Double(emitted) / elapsed : 0
                }
                var splitter = ReasoningSplitter()
                func send(_ segments: [ReasoningSplitter.Segment]) {
                    for segment in segments {
                        switch segment {
                        case .reasoning(let text): continuation.yield(.reasoning(text))
                        case .answer(let text): continuation.yield(.token(text))
                        }
                    }
                }
                do {
                    for token in tokens {
                        try await Task.sleep(for: delay)
                        send(splitter.process(token))
                        emitted += 1
                        if emitted.isMultiple(of: 8) {
                            continuation.yield(.stats(tokensPerSecond: tokensPerSecond()))
                        }
                    }
                    send(splitter.finish())
                    continuation.yield(.stats(tokensPerSecond: tokensPerSecond()))
                    if hitLimit {
                        continuation.yield(.lengthLimitReached)
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

    /// Splits text into word-sized tokens, each keeping its trailing whitespace,
    /// so concatenating the tokens reproduces the text exactly.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if !character.isWhitespace, let last = current.last, last.isWhitespace {
                tokens.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static let reasoning = """
        The user asks a question. I should answer briefly and clearly, \
        and keep the example short enough to read on a phone.
        """

    public static let defaultReplies: [String] = [
        """
        Hi! I'm a **scripted demo engine**, so this reply is canned, but it streams just like a real \
        model would.

        Everything here runs *on this device*:
        - no account
        - no cloud
        - no telemetry

        Downloaded models run on a real iPhone, iPad or Mac.
        """,
        """
        Good question. A local model answers in three steps:

        1. Your message and the earlier turns become the prompt.
        2. The model predicts one token at a time, using the phone's GPU.
        3. Each token appears here as soon as it is ready.

        That is why you can press **Stop** at any moment and keep what was written so far.
        """,
        """
        Here is a small Swift example:

        ```swift
        let stream = engine.reply(to: turn, history: [], options: options)
        for try await event in stream {
            print(event)
        }
        ```

        ## What each part does

        | Part | Role |
        | --- | --- |
        | `engine` | Runs the model on this device |
        | `turn` | Your message |

        > Tip: press **Stop** at any time. The text so far is kept.
        """,
    ]
}
