import SwiftUI

/// The unalome, drawn up to `progress` (0...1). The triangle appears when the line is complete.
///
/// Animate `progress` to draw it, or bind it to real progress such as a download.
/// The undrawn remainder stays visible as a faint track.
public struct UnalomeDrawing: View {
    private let progress: Double
    private let lineWidth: CGFloat
    private let tipDelay: Double

    /// - Parameter tipDelay: Seconds to hold the triangle back after `progress` reaches 1.
    ///   Set it to the duration of an animation that draws the line, so the triangle lands last.
    public init(progress: Double, lineWidth: CGFloat = 3, tipDelay: Double = 0) {
        self.progress = min(max(progress, 0), 1)
        self.lineWidth = lineWidth
        self.tipDelay = tipDelay
    }

    public var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let isComplete = progress >= 1
        ZStack {
            UnalomeLine()
                .stroke(Color.white.opacity(0.07), style: style)
            UnalomeLine()
                .trim(from: 0, to: progress)
                .stroke(Self.lineGradient, style: style)
                .shadow(color: UnalomeColor.teal.opacity(0.55), radius: 10)
            UnalomeTip()
                .fill(UnalomeGradient.brand)
                .shadow(color: UnalomeColor.teal.opacity(0.7), radius: 12)
                .opacity(isComplete ? 1 : 0)
                .scaleEffect(isComplete ? 1 : 0.4, anchor: .top)
                .animation(.spring(duration: 0.5, bounce: 0.45).delay(tipDelay), value: isComplete)
        }
        .aspectRatio(UnalomeGeometry.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// Dim at the spiral, full brand colour at the top: the line clears up as it rises.
    private static let lineGradient = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.35), location: 0),
            .init(color: UnalomeGradient.colors[0], location: 0.45),
            .init(color: UnalomeGradient.colors[1], location: 0.75),
            .init(color: UnalomeGradient.colors[2], location: 1),
        ],
        startPoint: .bottom,
        endPoint: .top)
}

/// Two soft, static glows behind a screen, as on unalome.ai's hero sections.
public struct GlowBackdrop: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                UnalomeColor.background
                RadialGradient(
                    colors: [UnalomeColor.emerald.opacity(0.20), .clear],
                    center: UnitPoint(x: 0.15, y: 0.22),
                    startRadius: 0,
                    endRadius: size.width * 0.9)
                RadialGradient(
                    colors: [UnalomeGradient.colors[2].opacity(0.11), .clear],
                    center: UnitPoint(x: 0.95, y: 0.62),
                    startRadius: 0,
                    endRadius: size.width * 0.8)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A thin line that fills with the brand gradient: the unalome's straight stroke as progress.
public struct ProgressLine: View {
    private let fraction: Double

    public init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }

    public var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.08))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(UnalomeGradient.brand)
                        .frame(width: max(proxy.size.width * fraction, 3))
                }
            }
            .frame(height: 3)
    }
}

public extension View {
    /// Fades and lifts the view into place once `isVisible` turns true, after `delay`.
    /// With Reduce Motion the view simply appears.
    func revealed(_ isVisible: Bool, delay: Double = 0) -> some View {
        modifier(RevealModifier(isVisible: isVisible, delay: delay))
    }
}

private struct RevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isVisible: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? nil : .smooth(duration: 0.7).delay(delay), value: isVisible)
    }
}
