import SwiftUI

// The two glass treatments from plan section 3. Every glass surface in the app goes through
// these modifiers, so changing how glass renders is a change in this file only.

public extension View {
    /// Liquid Glass (iOS 26 `glassEffect`) for floating chrome: the composer and pills.
    func liquidGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        glassEffect(.regular.interactive(interactive), in: shape)
    }

    /// The site's plain `.glass` surface for message cards: white 5% fill, 1 pt white 8% border.
    func plainGlass(in shape: some InsettableShape) -> some View {
        background { shape.fill(UnalomeColor.glassFill) }
            .overlay { shape.strokeBorder(UnalomeColor.glassBorder, lineWidth: 1) }
    }
}

/// A padded card with the plain glass surface and the card radius.
public struct GlassCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .plainGlass(in: RoundedRectangle(cornerRadius: UnalomeRadius.card, style: .continuous))
    }
}
