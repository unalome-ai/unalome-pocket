import SwiftUI

/// Text filled with the brand gradient, used for the second line of two-part headlines.
public struct GradientText: View {
    private let text: Text

    public init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    public var body: some View {
        text.foregroundStyle(UnalomeGradient.brand)
    }
}

/// A capsule on Liquid Glass.
public struct Pill<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlass(in: Capsule())
    }
}

/// Gradient-filled call-to-action button.
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .unalomeText(.headline)
            .foregroundStyle(UnalomeColor.background)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                UnalomeGradient.brand,
                in: RoundedRectangle(cornerRadius: UnalomeRadius.control, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .unalomeGlow()
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var unalomePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// The site's pulsing status dot. Static when Reduce Motion is on.
public struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    private let color: Color

    public init(color: Color = UnalomeColor.emerald) {
        self.color = color
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background {
                Circle()
                    .fill(color.opacity(0.5))
                    .scaleEffect(isPulsing ? 2.2 : 1)
                    .opacity(isPulsing ? 0 : 1)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// "● On device · <engine> · 34 tok/s", shown above the composer.
public struct StatusPill: View {
    private let engineName: String
    private let tokensPerSecond: Double?

    public init(engineName: String, tokensPerSecond: Double?) {
        self.engineName = engineName
        self.tokensPerSecond = tokensPerSecond
    }

    public var body: some View {
        Pill {
            HStack(spacing: 8) {
                PulsingDot()
                Text(statusLine)
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textSecondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var statusLine: String {
        var parts = ["On device", engineName]
        if let tokensPerSecond {
            parts.append("\(Int(tokensPerSecond.rounded())) tok/s")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var text = "Running on device with \(engineName)"
        if let tokensPerSecond {
            text += ", \(Int(tokensPerSecond.rounded())) tokens per second"
        }
        return text
    }
}
