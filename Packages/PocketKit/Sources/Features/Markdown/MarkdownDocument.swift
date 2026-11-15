import Foundation
import Markdown
import SwiftUI

/// A reply's Markdown as plain values, ready to render. Built with swift-markdown
/// (cmark-gfm), so lists, headings, code, tables, quotes and links follow CommonMark + GFM.
///
/// Values, not views: SwiftUI can compare blocks and skip the ones that did not change while
/// a reply streams, so only the last block re-renders as tokens arrive.
struct MarkdownDocument: Equatable {
    var blocks: [MarkdownBlock]

    init(parsing text: String) {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        blocks = document.children.compactMap(MarkdownBlock.init)
    }
}

indirect enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(language: String?, code: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case rule

    init?(_ markup: any Markup) {
        switch markup {
        case let paragraph as Paragraph:
            self = .paragraph(InlineBuilder.build(paragraph))
        case let heading as Heading:
            self = .heading(level: heading.level, InlineBuilder.build(heading))
        case let code as CodeBlock:
            // cmark keeps the fence's final newline; a still-streaming fence has none.
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            self = .code(language: code.language.flatMap { $0.isEmpty ? nil : $0 }, code: text)
        case let quote as BlockQuote:
            self = .quote(quote.children.compactMap(MarkdownBlock.init))
        case let list as OrderedList:
            self = .list(MarkdownList(ordered: true, start: Int(list.startIndex), items: list.listItems))
        case let list as UnorderedList:
            self = .list(MarkdownList(ordered: false, start: 1, items: list.listItems))
        case let table as Markdown.Table:
            self = .table(MarkdownTable(table))
        case is ThematicBreak:
            self = .rule
        case let html as HTMLBlock:
            self = .paragraph(AttributedString(html.rawHTML.trimmingCharacters(in: .newlines)))
        default:
            return nil
        }
    }
}

struct MarkdownList: Equatable {
    struct Item: Equatable {
        var checkbox: Bool?
        var blocks: [MarkdownBlock]
    }

    var ordered: Bool
    var start: Int
    var items: [Item]

    init(ordered: Bool, start: Int, items: some Sequence<ListItem>) {
        self.ordered = ordered
        self.start = start
        self.items = items.map { item in
            Item(
                checkbox: item.checkbox.map { $0 == .checked },
                blocks: item.children.compactMap(MarkdownBlock.init))
        }
    }
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing
    }

    var alignments: [Alignment]
    var header: [AttributedString]
    var rows: [[AttributedString]]

    init(_ table: Markdown.Table) {
        header = table.head.cells.map { InlineBuilder.build($0) }
        rows = table.body.rows.map { row in row.cells.map { InlineBuilder.build($0) } }
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        alignments = (0..<columns).map { index in
            guard index < table.columnAlignments.count else { return .leading }
            switch table.columnAlignments[index] {
            case .center: return .center
            case .right: return .trailing
            case .left, nil: return .leading
            }
        }
    }
}

/// Inline Markdown (emphasis, code, links, breaks) to an `AttributedString` for `Text`.
enum InlineBuilder {
    static func build(_ container: some Markup) -> AttributedString {
        var result = AttributedString()
        for child in container.children {
            append(child, to: &result, intent: [], link: nil, strikethrough: false)
        }
        return result
    }

    private static func append(
        _ markup: any Markup,
        to result: inout AttributedString,
        intent: InlinePresentationIntent,
        link: URL?,
        strikethrough: Bool
    ) {
        func appendText(_ string: String, extra: InlinePresentationIntent = []) {
            var piece = AttributedString(string)
            let combined = intent.union(extra)
            if !combined.isEmpty { piece.inlinePresentationIntent = combined }
            if let link { piece.link = link }
            if strikethrough { piece.strikethroughStyle = .single }
            result += piece
        }
        func appendChildren(intent: InlinePresentationIntent, link: URL?, strikethrough: Bool) {
            for child in markup.children {
                append(child, to: &result, intent: intent, link: link, strikethrough: strikethrough)
            }
        }

        switch markup {
        case let text as Markdown.Text:
            appendText(text.string)
        case let code as InlineCode:
            appendText(code.code, extra: .code)
        case is Emphasis:
            appendChildren(intent: intent.union(.emphasized), link: link, strikethrough: strikethrough)
        case is Strong:
            appendChildren(intent: intent.union(.stronglyEmphasized), link: link, strikethrough: strikethrough)
        case is Strikethrough:
            appendChildren(intent: intent, link: link, strikethrough: true)
        case let anchor as Markdown.Link:
            let url = anchor.destination.flatMap(URL.init(string:)).flatMap(safeLink)
            appendChildren(intent: intent, link: url ?? link, strikethrough: strikethrough)
        case is SoftBreak:
            appendText(" ")
        case is LineBreak:
            appendText("\n")
        case let html as InlineHTML:
            appendText(html.rawHTML)
        case let image as Markdown.Image:
            // No remote images: show the alt text.
            appendChildren(intent: intent, link: link, strikethrough: strikethrough)
            if image.childCount == 0, let source = image.source { appendText(source) }
        default:
            appendChildren(intent: intent, link: link, strikethrough: strikethrough)
        }
    }

    /// Only web and mail links open; anything else stays plain text.
    private static func safeLink(_ url: URL) -> URL? {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? url : nil
    }
}
