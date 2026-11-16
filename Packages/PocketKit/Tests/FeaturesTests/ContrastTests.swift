import Testing
import UnalomeDesign

/// Text colours meet WCAG AA (4.5:1) on every surface they sit on.
struct ContrastTests {
    static let background: UInt32 = 0x06050A
    static let raised: UInt32 = 0x0D0B14

    @Test func tertiaryTextPassesOnEverySurface() {
        let opacity = UnalomeColor.textTertiaryOpacity
        #expect(Contrast.whiteText(opacity: opacity, on: Self.background) >= 4.5)
        #expect(Contrast.whiteText(opacity: opacity, on: Self.raised) >= 4.5)
        // Glass: white 5% over the background.
        #expect(Contrast.whiteText(opacity: opacity, on: Self.background, glass: 0.05) >= 4.5)
    }

    @Test func secondaryTextPasses() {
        #expect(Contrast.whiteText(opacity: UnalomeColor.textSecondaryOpacity, on: Self.raised, glass: 0.05) >= 4.5)
    }

    @Test func theOldTertiaryValueFailed() {
        #expect(Contrast.whiteText(opacity: 0.4, on: Self.background) < 4.5)
    }

    @Test func pureWhiteOnBlackIsTwentyOne() {
        #expect(abs(Contrast.whiteText(opacity: 1, on: 0x000000) - 21) < 0.01)
    }
}
