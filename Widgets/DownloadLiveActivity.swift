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
                .activityBackgroundTint(UnalomeColor.background)
                .activitySystemActionForegroundColor(UnalomeColor.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    UnalomeMark(height: 28)
                        .padding(.leading, 4)
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
                UnalomeMark(height: 18)
            } compactTrailing: {
                Text(context.state.percentText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(UnalomeColor.teal)
            } minimal: {
                UnalomeMark(height: 18)
            }
        }
    }
}

private struct LockScreenDownloadView: View {
    let attributes: DownloadActivityAttributes
    let content: DownloadActivityContent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            UnalomeMark(height: 34)
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
