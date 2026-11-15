/// Separates a model's reasoning from its answer in a streamed reply.
///
/// Reasoning models wrap their thoughts in delimiters such as `<think>…</think>`. The splitter
/// is fed decoded chunks as they arrive and returns what belongs to the reasoning and what to
/// the answer. It copes with:
/// - a delimiter split across chunks (a possible partial delimiter is held back until it is
///   clear whether it is one);
/// - a prompt that already opened the block (`primedInside`), so the output starts inside the
///   reasoning and only the closing delimiter appears;
/// - a reply that stops before the closing delimiter (everything so far is reasoning).
///
/// Whitespace right after a delimiter is dropped, as chat templates put newlines there.
public struct ReasoningSplitter: Sendable {
    public enum Segment: Sendable, Equatable {
        case reasoning(String)
        case answer(String)
    }

    public static let thinkTags = (start: "<think>", end: "</think>")

    public let start: String
    public let end: String
    private var inside: Bool
    private var pending = ""
    private var trimLeadingWhitespace: Bool
    /// Primed, and nothing seen yet: a repeated opening delimiter is dropped.
    private var awaitingPrimedStart: Bool

    public init(start: String = ReasoningSplitter.thinkTags.start, end: String = ReasoningSplitter.thinkTags.end,
                primedInside: Bool = false)
    {
        precondition(!start.isEmpty && !end.isEmpty, "Delimiters must not be empty")
        self.start = start
        self.end = end
        self.inside = primedInside
        self.trimLeadingWhitespace = primedInside
        self.awaitingPrimedStart = primedInside
    }

    /// Whether the rendered prompt ends inside an open reasoning block, i.e. its last
    /// `start` delimiter comes after its last `end` delimiter.
    public static func promptEndsInsideReasoning(_ promptTail: String, start: String, end: String) -> Bool {
        guard let open = promptTail.range(of: start, options: .backwards) else { return false }
        guard let close = promptTail.range(of: end, options: .backwards) else { return true }
        return open.lowerBound > close.lowerBound
    }

    public var isInsideReasoning: Bool { inside }

    /// Routes one chunk. Returns the segments that are certain so far, in order.
    public mutating func process(_ chunk: String) -> [Segment] {
        var text = pending + chunk
        pending = ""
        var segments: [Segment] = []
        if awaitingPrimedStart {
            // Some models repeat the opening delimiter the template already wrote.
            let head = text.drop { $0.isWhitespace }
            if head.isEmpty || (start.hasPrefix(head) && head.count < start.count) {
                pending = text
                return []
            }
            awaitingPrimedStart = false
            if head.hasPrefix(start) {
                text = String(head.dropFirst(start.count))
            }
        }
        while !text.isEmpty {
            let delimiter = inside ? end : start
            if let range = text.range(of: delimiter) {
                emit(String(text[..<range.lowerBound]), into: &segments)
                text = String(text[range.upperBound...])
                inside.toggle()
                trimLeadingWhitespace = true
                continue
            }
            // Hold back a tail that could be the beginning of the delimiter.
            let keep = Self.longestSuffix(of: text, thatPrefixes: delimiter)
            emit(String(text.dropLast(keep)), into: &segments)
            pending = String(text.suffix(keep))
            break
        }
        return segments
    }

    /// Flushes held-back text at the end of the stream.
    public mutating func finish() -> [Segment] {
        awaitingPrimedStart = false
        var segments: [Segment] = []
        emit(pending, into: &segments)
        pending = ""
        return segments
    }

    private mutating func emit(_ piece: String, into segments: inout [Segment]) {
        var piece = Substring(piece)
        if trimLeadingWhitespace {
            piece = piece.drop { $0.isWhitespace }
            if piece.isEmpty { return }
            trimLeadingWhitespace = false
        }
        guard !piece.isEmpty else { return }
        let text = String(piece)
        switch (inside, segments.last) {
        case (true, .reasoning(let previous)?):
            segments[segments.count - 1] = .reasoning(previous + text)
        case (false, .answer(let previous)?):
            segments[segments.count - 1] = .answer(previous + text)
        case (true, _):
            segments.append(.reasoning(text))
        case (false, _):
            segments.append(.answer(text))
        }
    }

    private static func longestSuffix(of text: String, thatPrefixes delimiter: String) -> Int {
        let maximum = min(text.count, delimiter.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) where delimiter.hasPrefix(text.suffix(length)) {
            return length
        }
        return 0
    }
}
