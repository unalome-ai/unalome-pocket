import SwiftUI
import UnalomeDesign

/// Block-level Markdown for replies: paragraphs, headings, lists, code blocks with a copy
/// button, tables, quotes and links, in the Unalome type and colours.
///
/// Equatable on its text, so finished replies are not re-parsed when the list redraws; while
/// a reply streams, blocks keep their position as identity and unchanged blocks are skipped.
struct MarkdownView: View, Equatable {
    let text: String

    var body: some View {
        let document = MarkdownDocument(parsing: text)
        BlockStack(blocks: document.blocks, spacing: 12)
    }
}

private struct BlockStack: View {
    let blocks: [MarkdownBlock]
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                BlockView(block: blocks[index]).equatable()
            }
        }
    }
}

private struct BlockView: View, Equatable {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .unalomeText(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(text)
                .unalomeText(level <= 1 ? .title : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(UnalomeGradient.brand)
                    .frame(width: 3)
                BlockStack(blocks: blocks, spacing: 8)
                    .foregroundStyle(UnalomeColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            ListView(list: list)
        case .table(let table):
            TableView(table: table)
        case .rule:
            Rectangle()
                .fill(UnalomeColor.glassBorder)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }
}

private struct ListView: View {
    let list: MarkdownList
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item, at: index)
                        .frame(minWidth: markerWidth, alignment: .trailing)
                    BlockStack(blocks: item.blocks, spacing: 6)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownList.Item, at index: Int) -> some View {
        if let checked = item.checkbox {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? UnalomeColor.emerald : UnalomeColor.textTertiary)
                .unalomeText(.body)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else {
            Text(list.ordered ? "\(list.start + index)." : "•")
                .unalomeText(.body)
                .monospacedDigit()
                .foregroundStyle(UnalomeColor.textTertiary)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UnalomeRadius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .unalomeText(.eyebrow)
                    .foregroundStyle(UnalomeColor.textTertiary)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .unalomeText(.footnote)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? UnalomeColor.emerald : UnalomeColor.textSecondary)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(UnalomeColor.glassBorder).frame(height: 1)
            ScrollView(.horizontal) {
                Text(code)
                    .unalomeText(.code)
                    .foregroundStyle(UnalomeColor.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .scrollIndicators(.hidden)
        }
        .plainGlass(in: shape)
        .clipShape(shape)
        .onChange(of: code) { copied = false }
    }
}

private struct TableView: View {
    let table: MarkdownTable

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UnalomeRadius.control, style: .continuous)
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column)
                            .unalomeText(.headline)
                    }
                }
                .background(UnalomeColor.glassFill)
                ForEach(table.rows.indices, id: \.self) { row in
                    Divider().overlay(UnalomeColor.glassBorder)
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column)
                                .unalomeText(.callout)
                        }
                    }
                }
            }
            .plainGlass(in: shape)
            .clipShape(shape)
        }
        .scrollIndicators(.hidden)
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(text)
            .frame(minWidth: 60, maxWidth: 280, alignment: frameAlignment(alignment))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .gridColumnAlignment(horizontalAlignment(alignment))
    }

    private func frameAlignment(_ alignment: MarkdownTable.Alignment) -> SwiftUI.Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func horizontalAlignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
