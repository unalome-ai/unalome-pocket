import ActivityKit
import PocketShared
import SwiftUI
import UnalomeDesign
import WidgetKit

/// A model download on the Lock Screen and in the Dynamic Island.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenDownloadView(attributes: context.attributes, content: context.state)
                .background { WidgetGlow() }
                .activityBackgroundTint(UnalomeColor.background)
                .activitySystemActionForegroundColor(UnalomeColor.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    UnalomeProgress(fraction: context.state.fraction, height: 44, lineWidth: 1.8)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.percentText)
                        .unalomeText(.headline)
                        .monospacedDigit()
                        .foregroundStyle(UnalomeColor.textPrimary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.modelName)
                        .unalomeText(.headline)
                        .foregroundStyle(UnalomeColor.textPrimary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressLine(fraction: context.state.fraction)
                        DownloadDetail(content: context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                UnalomeProgress(fraction: context.state.fraction, height: 22, lineWidth: 1.4)
            } compactTrailing: {
                Text(context.state.percentText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(UnalomeColor.teal)
            } minimal: {
                UnalomeProgress(fraction: context.state.fraction, height: 22, lineWidth: 1.4)
            }
        }
    }
}

private struct LockScreenDownloadView: View {
    let attributes: DownloadActivityAttributes
    let content: DownloadActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            UnalomeProgress(fraction: content.fraction, height: 56, lineWidth: 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(attributes.modelName)
                        .unalomeText(.headline)
                        .foregroundStyle(UnalomeColor.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(content.percentText)
                        .unalomeText(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(UnalomeColor.textSecondary)
                }
                ProgressLine(fraction: content.fraction)
                DownloadDetail(content: content)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// "1.2 GB of 3.1 GB · Downloading", or the paused, checking, done and failed lines.
private struct DownloadDetail: View {
    let content: DownloadActivityContent

    var body: some View {
        Text(line)
            .unalomeText(.footnote)
            .foregroundStyle(content.phase == .failed ? UnalomeColor.error : UnalomeColor.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var line: String {
        switch content.phase {
        case .done, .failed, .verifying:
            return content.statusText
        case .downloading, .paused:
            let done = ByteCountFormatter.string(fromByteCount: content.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: content.totalBytes, countStyle: .file)
            return "\(done) of \(total) · \(content.statusText)"
        }
    }
}

/// The download as the unalome itself: the line is drawn from the spiral upwards as bytes
/// arrive, and the triangle lights when the model is ready.
struct UnalomeProgress: View {
    let fraction: Double
    let height: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let clamped = min(max(fraction, 0), 1)
        ZStack {
            UnalomeLine().stroke(Color.white.opacity(0.16), style: style)
            UnalomeLine()
                .trim(from: 0, to: clamped)
                .stroke(
                    LinearGradient(colors: UnalomeGradient.colors, startPoint: .bottom, endPoint: .top),
                    style: style)
            UnalomeTip()
                .fill(UnalomeGradient.brand)
                .opacity(clamped >= 1 ? 1 : 0.2)
        }
        // The figure's width is 0.46 of its height.
        .frame(width: height * 0.46, height: height)
        .accessibilityHidden(true)
    }
}
