import Foundation
import Testing
@testable import Features

struct MarkdownDocumentTests {
    @Test func parsesBlocks() throws {
        let text = """
            # Title

            Some **bold** and `code`.

            * Input: a
            * Output: b

            1. one
            2. two

            ```swift
            let x = 1
            ```

            | A | B |
            |:--|--:|
            | 1 | 2 |

            > quoted

            ---
            """
        let blocks = MarkdownDocument(parsing: text).blocks
        #expect(blocks.count == 8)
        guard case .heading(1, _) = blocks[0] else { Issue.record("heading"); return }
        guard case .list(let bullets) = blocks[2], case .list(let numbers) = blocks[3] else {
            Issue.record("lists")
            return
        }
        #expect(!bullets.ordered && bullets.items.count == 2)
        #expect(numbers.ordered && numbers.start == 1 && numbers.items.count == 2)
        #expect(blocks[4] == .code(language: "swift", code: "let x = 1"))
        guard case .table(let table) = blocks[5] else { Issue.record("table"); return }
        #expect(table.alignments == [.leading, .trailing])
        #expect(table.rows.count == 1)
        guard case .quote = blocks[6], case .rule = blocks[7] else { Issue.record("quote/rule"); return }
    }

    @Test func inlineStylesBecomeAttributes() throws {
        guard case .paragraph(let text) = MarkdownDocument(parsing: "**b** *i* `c` [l](https://example.com)").blocks.first
        else {
            Issue.record("paragraph")
            return
        }
        #expect(String(text.characters) == "b i c l")
        let runs = text.runs.map { ($0.inlinePresentationIntent, $0.link) }
        #expect(runs.contains { $0.0 == .stronglyEmphasized })
        #expect(runs.contains { $0.0 == .emphasized })
        #expect(runs.contains { $0.0 == .code })
        #expect(runs.contains { $0.1 == URL(string: "https://example.com") })
    }

    @Test func unsafeLinksStayPlainText() {
        guard case .paragraph(let text) = MarkdownDocument(parsing: "[x](javascript:alert(1))").blocks.first else {
            Issue.record("paragraph")
            return
        }
        #expect(text.runs.allSatisfy { $0.link == nil })
    }

    /// While streaming, an unfinished code fence is already a code block, and earlier blocks
    /// keep their values, so they do not re-render.
    @Test func streamingKeepsEarlierBlocksStable() {
        let first = MarkdownDocument(parsing: "Intro.\n\n```py\nprint(1")
        let later = MarkdownDocument(parsing: "Intro.\n\n```py\nprint(1)\nprint(2)\n```\n\nAfter")
        #expect(first.blocks.first == later.blocks.first)
        #expect(first.blocks.last == .code(language: "py", code: "print(1"))
    }

    @Test func parsesALongReplyQuickly() {
        let paragraph = "Some **text** with `code` and a [link](https://example.com). "
        let section = "## Heading\n\n" + String(repeating: paragraph, count: 6) + "\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n"
        let text = String(repeating: section, count: 20)  // roughly 2,500 tokens
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 { _ = MarkdownDocument(parsing: text) }
        }
        #expect(elapsed / 10 < .milliseconds(50), "one parse took \(elapsed / 10)")
    }
}
