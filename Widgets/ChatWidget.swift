import PocketShared
import SwiftUI
import UnalomeDesign
import WidgetKit

/// The latest chat, read from the snapshot the app writes to the App Group. The app reloads
/// the widgets when a reply finishes or a chat is deleted, so the timeline never refreshes itself.
struct ChatEntry: TimelineEntry {
    var date: Date
    var latest: WidgetSnapshot?
}

struct ChatProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChatEntry {
        ChatEntry(date: .now, latest: WidgetSnapshot(
            conversationID: UUID(), title: "Moon facts", replyExcerpt: "The Moon is tidally locked to Earth.",
            updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (ChatEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChatEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> ChatEntry {
        ChatEntry(date: .now, latest: WidgetSnapshotStore.shared()?.read())
    }
}

struct ChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.unalome.pocket.chat", provider: ChatProvider()) { entry in
            ChatWidgetView(entry: entry)
        }
        .configurationDisplayName("Unalome Pocket")
        .description("Start a chat, ask by voice, or pick up your latest chat. Everything runs on this device.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct ChatWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ChatEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    private var isFullColor: Bool { renderingMode == .fullColor }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                UnalomeMark(height: 30)
                Spacer()
                OnDeviceDot()
            }
            Spacer()
            // The site's two-part headline: plain first line, brand gradient second.
            Text("Ask anything.")
                .unalomeText(.headline)
                .foregroundStyle(UnalomeColor.textPrimary)
            Text("On this device.")
                .unalomeText(.headline)
                .foregroundStyle(isFullColor ? AnyShapeStyle(UnalomeGradient.brand) : AnyShapeStyle(.secondary))
                .widgetAccentable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New chat in Unalome Pocket")
        .widgetURL(AppRoute.newChat.url)
        .containerBackground(for: .widget) { background }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                UnalomeMark(height: 26)
                Spacer(minLength: 0)
                action("New chat", systemImage: "square.and.pencil", route: .newChat)
                action("Ask by voice", systemImage: "mic", route: .voice)
            }
            .frame(width: 118, alignment: .leading)

            Capsule()
                .fill(isFullColor ? AnyShapeStyle(UnalomeGradient.brand) : AnyShapeStyle(.tertiary))
                .frame(width: 2)
                .opacity(0.7)
                .accessibilityHidden(true)

            latestChat
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .containerBackground(for: .widget) { background }
    }

    private func action(_ title: String, systemImage: String, route: AppRoute) -> some View {
        Link(destination: route.url) {
            Label(title, systemImage: systemImage)
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .plainGlass(in: Capsule())
        }
    }

    @ViewBuilder
    private var latestChat: some View {
        if let latest = entry.latest {
            Link(destination: AppRoute.conversation(latest.conversationID).url) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest chat")
                        .unalomeText(.eyebrow)
                        .foregroundStyle(UnalomeColor.textTertiary)
                    Text(latest.title)
                        .unalomeText(.headline)
                        .foregroundStyle(UnalomeColor.textPrimary)
                        .lineLimit(2)
                    if !latest.replyExcerpt.isEmpty {
                        Text(latest.replyExcerpt)
                            .unalomeText(.footnote)
                            .foregroundStyle(UnalomeColor.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No chats yet")
                    .unalomeText(.headline)
                    .foregroundStyle(UnalomeColor.textPrimary)
                Text("Your chats stay on this device.")
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if isFullColor {
            WidgetGlow()
        } else {
            Color.clear
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            UnalomeMark(height: 26)
                .widgetAccentable()
        }
        .widgetURL(AppRoute.newChat.url)
        .accessibilityLabel("New chat in Unalome Pocket")
        .containerBackground(for: .widget) { Color.clear }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Unalome Pocket")
                .font(.headline)
                .widgetAccentable()
            if let latest = entry.latest {
                Text(latest.title).font(.caption).lineLimit(1)
                if !latest.replyExcerpt.isEmpty {
                    Text(latest.replyExcerpt).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Ask on this device").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.latest.map { AppRoute.conversation($0.conversationID).url } ?? AppRoute.newChat.url)
        .containerBackground(for: .widget) { Color.clear }
    }
}

/// The app's backdrop at widget size: the base colour lifted by two soft glows.
struct WidgetGlow: View {
    var body: some View {
        ZStack {
            UnalomeColor.background
            RadialGradient(
                colors: [UnalomeColor.emerald.opacity(0.26), .clear],
                center: UnitPoint(x: 0.1, y: 0.05), startRadius: 0, endRadius: 190)
            RadialGradient(
                colors: [UnalomeGradient.colors[2].opacity(0.13), .clear],
                center: UnitPoint(x: 1.0, y: 0.95), startRadius: 0, endRadius: 170)
        }
    }
}

/// The site's status dot: a small lit point that says the model is local.
struct OnDeviceDot: View {
    var body: some View {
        Circle()
            .fill(UnalomeColor.emerald)
            .frame(width: 7, height: 7)
            .shadow(color: UnalomeColor.emerald.opacity(0.8), radius: 4)
            .padding(.top, 4)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}
