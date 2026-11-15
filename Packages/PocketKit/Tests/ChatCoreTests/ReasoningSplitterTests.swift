import Testing
@testable import ChatCore

struct ReasoningSplitterTests {
    /// Feeds `chunks` and returns (reasoning, answer) as joined text.
    private func split(_ chunks: [String], primed: Bool = false, start: String = "<think>", end: String = "</think>")
        -> (reasoning: String, answer: String)
    {
        var splitter = ReasoningSplitter(start: start, end: end, primedInside: primed)
        var reasoning = ""
        var answer = ""
        for segment in chunks.flatMap({ splitter.process($0) }) + splitter.finish() {
            switch segment {
            case .reasoning(let text): reasoning += text
            case .answer(let text): answer += text
            }
        }
        return (reasoning, answer)
    }

    @Test func plainAnswerPassesThrough() {
        let result = split(["Hello", " there", ", 2 < 3."])
        #expect(result.answer == "Hello there, 2 < 3.")
        #expect(result.reasoning.isEmpty)
    }

    @Test func separatesAThinkBlock() {
        let result = split(["<think>\nLet me see.\n</think>\n\nHi!"])
        #expect(result.reasoning == "Let me see.\n")
        #expect(result.answer == "Hi!")
    }

    @Test(arguments: [1, 2, 3, 5, 7])
    func tagsSplitAcrossChunks(size: Int) {
        let text = "<think>Plan the reply.</think>\n\nThe answer is 4."
        let chunks = stride(from: 0, to: text.count, by: size).map { offset in
            String(text.dropFirst(offset).prefix(size))
        }
        let result = split(chunks)
        #expect(result.reasoning == "Plan the reply.")
        #expect(result.answer == "The answer is 4.")
    }

    @Test func missingClosingTagKeepsEverythingAsReasoning() {
        // The reply hit the length limit while still thinking.
        let result = split(["<think>Step 1", ". Step 2", ". Step 3 </th"])
        #expect(result.reasoning == "Step 1. Step 2. Step 3 </th")
        #expect(result.answer.isEmpty)
    }

    @Test func templateOpenedBlockStartsInsideReasoning() {
        // Qwen with thinking on ends the prompt with "<think>\n", so the output has no opening tag.
        let result = split(["Thinking Process:\n1. Analyze", " the input.\n</", "think>\n\nHello!"], primed: true)
        #expect(result.reasoning == "Thinking Process:\n1. Analyze the input.\n")
        #expect(result.answer == "Hello!")
    }

    @Test func primedButModelRepeatsTheOpeningTag() {
        let result = split(["<thi", "nk>\nHmm.</think>Done"], primed: true)
        #expect(result.reasoning == "Hmm.")
        #expect(result.answer == "Done")
    }

    @Test func emptyThinkBlockFromATemplateWithThinkingOff() {
        let result = split(["<think>\n\n</think>\n\n", "Sure."])
        #expect(result.reasoning.isEmpty)
        #expect(result.answer == "Sure.")
    }

    @Test func gemmaChannelDelimiters() {
        let result = split(
            ["<|chan", "nel>thought\nCheck units.<chan", "nel|>It is 5 km."],
            start: "<|channel>thought", end: "<channel|>")
        #expect(result.reasoning == "Check units.")
        #expect(result.answer == "It is 5 km.")
    }

    @Test func detectsPromptsThatEndInsideReasoning() {
        #expect(ReasoningSplitter.promptEndsInsideReasoning(
            "<|im_start|>assistant\n<think>\n", start: "<think>", end: "</think>"))
        #expect(!ReasoningSplitter.promptEndsInsideReasoning(
            "<|im_start|>assistant\n<think>\n\n</think>\n\n", start: "<think>", end: "</think>"))
        #expect(!ReasoningSplitter.promptEndsInsideReasoning(
            "<|im_start|>assistant\n", start: "<think>", end: "</think>"))
    }
}
