import SwiftUI

/// One thing a model can do, shown as a small glass pill: a symbol and a word.
public struct CapabilityPill: View {
    public struct Item: Hashable, Sendable {
        public var title: String
        public var systemImage: String
        /// Teal for the capabilities that set models apart (image, thinking).
        public var isAccented: Bool

        public init(title: String, systemImage: String, isAccented: Bool = false) {
            self.title = title
            self.systemImage = systemImage
            self.isAccented = isAccented
        }
    }

    private let item: Item

    public init(_ item: Item) {
        self.item = item
    }

    public var body: some View {
        let color = item.isAccented ? UnalomeColor.teal : UnalomeColor.textSecondary
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.systemImage)
                .imageScale(.small)
        }
        .labelStyle(PillLabelStyle())
        .unalomeText(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(item.isAccented ? UnalomeColor.teal.opacity(0.08) : Color.clear)
        }
        .plainGlass(in: Capsule())
        .fixedSize()
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// A model's capabilities as a row of pills that wraps onto more lines rather than truncating.
/// VoiceOver reads it as one sentence, e.g. "Supports text, image, voice, thinking".
public struct CapabilityPills: View {
    private let items: [CapabilityPill.Item]
    private let accessibilityText: String

    /// - Parameter accessibilityText: The spoken summary; built from the titles when `nil`.
    public init(_ items: [CapabilityPill.Item], accessibilityText: String? = nil) {
        self.items = items
        self.accessibilityText = accessibilityText ?? Self.summary(items.map(\.title))
    }

    public var body: some View {
        WrappingRow(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { CapabilityPill($0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Supports text, image, voice, thinking".
    public static func summary(_ titles: [String]) -> String {
        "Supports " + titles.map { $0.lowercased() }.joined(separator: ", ")
    }
}

/// Lays children out left to right, starting a new line when the next one does not fit.
struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
