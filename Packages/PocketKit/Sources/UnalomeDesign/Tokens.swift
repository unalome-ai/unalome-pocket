import SwiftUI

/// Colour tokens taken from the unalome.ai stylesheet (plan section 3).
public enum UnalomeColor {
    /// Base background, `#06050a`.
    public static let background = Color(hex: 0x06050A)
    /// Raised background, `#0d0b14`.
    public static let backgroundRaised = Color(hex: 0x0D0B14)

    /// Glass surface fill: white at 5%.
    public static let glassFill = Color.white.opacity(0.05)
    /// Glass surface border: white at 8%, drawn 1 pt wide.
    public static let glassBorder = Color.white.opacity(0.08)

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.6)
    public static let textTertiary = Color.white.opacity(0.4)

    /// Accent solids.
    public static let emerald = Color(hex: 0x10B981)
    public static let teal = Color(hex: 0x14B8A6)

    public static let warning = Color(hex: 0xFBBF24)
    public static let error = Color(hex: 0xF43F5E)
}

/// The master brand gradient: `#34d399` → `#2dd4bf` → `#22d3ee` at 135°.
public enum UnalomeGradient {
    public static let colors: [Color] = [
        Color(hex: 0x34D399),
        Color(hex: 0x2DD4BF),
        Color(hex: 0x22D3EE),
    ]

    /// CSS 135° runs from the top-left corner to the bottom-right corner.
    public static let brand = LinearGradient(
        colors: colors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Corner radii: 16 for cards, 12 for controls; pills use `Capsule`.
public enum UnalomeRadius {
    public static let card: CGFloat = 16
    public static let control: CGFloat = 12
}

public extension View {
    /// The site's glow, `0 0 80px` accent at 20%.
    /// CSS blur radius is twice the Gaussian deviation SwiftUI's `radius` describes, hence 40.
    func unalomeGlow(_ color: Color = UnalomeColor.emerald) -> some View {
        shadow(color: color.opacity(0.2), radius: 40)
    }
}

extension Color {
    /// Creates an opaque sRGB colour from a `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
