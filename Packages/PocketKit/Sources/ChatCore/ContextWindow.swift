/// Keeps a conversation within a model's context window by dropping the oldest turns.
public enum ContextWindow {
    /// A rough token count: about 3.5 characters per token for English text, rounded up,
    /// plus a few tokens of chat-template overhead per turn. Images count as a fixed block.
    /// Deliberately on the high side so a trimmed history fits.
    public static func estimatedTokens(_ turn: ChatTurn) -> Int {
        (turn.text.utf8.count * 2 + 6) / 7 + 8 + turn.images.count * imageTokens
    }

    static let imageTokens = 1024

    public struct Result: Equatable, Sendable {
        /// System turns plus the newest turns that fit.
        public var history: [ChatTurn]
        /// How many earlier non-system turns were left out.
        public var droppedCount: Int
    }

    /// Fits `history` + `turn` + `replyTokens` into `contextTokens`. System turns are always kept;
    /// conversation turns are dropped oldest first, and the kept part starts with a user turn.
    /// At most half the window is held back for the reply, so a long reply cap (thinking) on a
    /// small window still leaves room for the conversation.
    public static func fit(history: [ChatTurn], turn: ChatTurn, contextTokens: Int, replyTokens: Int) -> Result {
        let system = history.filter { $0.role == .system }
        let conversation = history.filter { $0.role != .system }
        let reserved = min(replyTokens, contextTokens / 2)
        var budget = contextTokens - reserved - estimatedTokens(turn) - system.map(estimatedTokens).reduce(0, +)
        var keptFrom = conversation.count
        for index in conversation.indices.reversed() {
            let cost = estimatedTokens(conversation[index])
            guard cost <= budget else { break }
            budget -= cost
            keptFrom = index
        }
        // Do not start on an assistant turn: its question would be missing.
        while keptFrom < conversation.count, conversation[keptFrom].role == .assistant {
            keptFrom += 1
        }
        return Result(history: system + conversation[keptFrom...], droppedCount: keptFrom)
    }
}
