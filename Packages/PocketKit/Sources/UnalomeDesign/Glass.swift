import SwiftUI

// The two glass treatments from plan section 3. Every glass surface in the app goes through
// these modifiers, so changing how glass renders is a change in this file only.

public extension View {
    /// Liquid Glass (iOS 26 `glassEffect`) for floating chrome: the composer and pills.
    /// With Reduce Transparency it is a solid raised surface with a border instead.
    func liquidGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(shape: shape, interactive: interactive))
    }

    /// The site's plain `.glass` surface for message cards: white 5% fill, 1 pt white 8% border.
    /// With Reduce Transparency the fill is the solid raised background.
    func plainGlass(in shape: some InsettableShape) -> some View {
        modifier(PlainGlassModifier(shape: shape))
    }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background { shape.fill(UnalomeColor.backgroundRaised) }
                .overlay { shape.stroke(Color.white.opacity(0.18), lineWidth: 1) }
        } else {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        }
    }
}

private struct PlainGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background { shape.fill(reduceTransparency ? UnalomeColor.backgroundRaised : UnalomeColor.glassFill) }
            .overlay {
                shape.strokeBorder(
                    reduceTransparency ? Color.white.opacity(0.18) : UnalomeColor.glassBorder, lineWidth: 1)
            }
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
