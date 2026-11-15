import CoreText
import SwiftUI

/// Inter (bundled, OFL) with a system-font fallback.
public enum UnalomeFont {
    /// Registers the bundled variable font once, on first use.
    /// `false` means registration failed and every style falls back to the system font.
    public static let isInterAvailable: Bool = registerInter()

    private static func registerInter() -> Bool {
        guard let url = Bundle.module.url(forResource: "InterVariable", withExtension: "ttf") else {
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }
        guard let cfError = error?.takeRetainedValue() else { return false }
        return CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue
    }

    /// The font for a text style. Scales with Dynamic Type.
    public static func font(_ style: UnalomeTextStyle) -> Font {
        let spec = style.spec
        if spec.isMonospaced {
            return .system(spec.relativeTo, design: .monospaced, weight: spec.weight.systemWeight)
        }
        guard isInterAvailable else {
            return .system(spec.relativeTo, weight: spec.weight.systemWeight)
        }
        return .custom(spec.weight.interPostScriptName, size: spec.size, relativeTo: spec.relativeTo)
    }
}

/// The app's text styles. Each scales relative to a system text style, so Dynamic Type applies.
public enum UnalomeTextStyle: Sendable, CaseIterable {
    /// Two-part headlines ("Nothing leaves / this phone."): extrabold, tracking −0.025em.
    case display
    /// Screen and section titles: bold, tracking −0.025em.
    case title
    case headline
    case body
    case callout
    case footnote
    /// Eyebrow labels: 11 pt, uppercase, tracking 0.1em.
    case eyebrow
    /// SF Mono for code.
    case code

    struct Spec {
        var size: CGFloat
        var weight: InterWeight
        var relativeTo: Font.TextStyle
        var trackingEm: CGFloat = 0
        var isUppercase = false
        var isMonospaced = false
    }

    var spec: Spec {
        switch self {
        case .display: Spec(size: 34, weight: .extraBold, relativeTo: .largeTitle, trackingEm: -0.025)
        case .title: Spec(size: 22, weight: .bold, relativeTo: .title2, trackingEm: -0.025)
        case .headline: Spec(size: 17, weight: .semibold, relativeTo: .headline)
        case .body: Spec(size: 17, weight: .regular, relativeTo: .body)
        case .callout: Spec(size: 15, weight: .regular, relativeTo: .callout)
        case .footnote: Spec(size: 13, weight: .medium, relativeTo: .footnote)
        case .eyebrow: Spec(size: 11, weight: .semibold, relativeTo: .caption2, trackingEm: 0.1, isUppercase: true)
        case .code: Spec(size: 15, weight: .regular, relativeTo: .callout, isMonospaced: true)
        }
    }
}

/// Weights 400–900 of the variable font, addressed by their named-instance PostScript names.
/// CoreText resolves these names to the matching `wght` axis value of `InterVariable.ttf`.
enum InterWeight: CaseIterable {
    case regular, medium, semibold, bold, extraBold, black

    var interPostScriptName: String {
        switch self {
        case .regular: "InterVariable"
        case .medium: "InterVariable-Medium"
        case .semibold: "InterVariable-SemiBold"
        case .bold: "InterVariable-Bold"
        case .extraBold: "InterVariable-ExtraBold"
        case .black: "InterVariable-Black"
        }
    }

    var systemWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .extraBold: .heavy
        case .black: .black
        }
    }
}

private struct UnalomeTextModifier: ViewModifier {
    let style: UnalomeTextStyle
    /// Tracking is specified in em, so it follows the Dynamic Type-scaled size.
    @ScaledMetric private var scaledSize: CGFloat

    init(style: UnalomeTextStyle) {
        self.style = style
        _scaledSize = ScaledMetric(wrappedValue: style.spec.size, relativeTo: style.spec.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(UnalomeFont.font(style))
            .tracking(style.spec.trackingEm * scaledSize)
            .textCase(style.spec.isUppercase ? .uppercase : nil)
    }
}

public extension View {
    /// Applies an Unalome text style: font, tracking and case.
    func unalomeText(_ style: UnalomeTextStyle) -> some View {
        modifier(UnalomeTextModifier(style: style))
    }
}
