import ChatCore
import Foundation
import PocketShared

/// Writes the widgets' snapshot (the most recent chat) after a reply finishes or a chat is
/// deleted, then asks WidgetKit to reload. The chats stay in the app's own store.
@MainActor
public struct WidgetSnapshotPublisher {
    let store: WidgetSnapshotStore
    let reload: @MainActor () -> Void

    /// - Parameter reload: Usually `WidgetCenter.shared.reloadAllTimelines()`.
    public init(store: WidgetSnapshotStore, reload: @escaping @MainActor () -> Void) {
        self.store = store
        self.reload = reload
    }

    /// The snapshot for conversations sorted most recent first: the first one, with its latest
    /// non-empty reply. `nil` when there are no chats.
    public static func snapshot(of conversations: [Conversation]) -> WidgetSnapshot? {
        guard let latest = conversations.first else { return nil }
        let reply = latest.orderedMessages.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? ""
        return WidgetSnapshot(
            conversationID: latest.id,
            title: latest.displayTitle,
            replyExcerpt: WidgetSnapshot.excerpt(fromReply: reply),
            updatedAt: latest.updatedAt)
    }

    public func publish(from conversations: ConversationStore) {
        guard let all = try? conversations.conversations() else { return }
        if (try? store.write(Self.snapshot(of: all))) == true {
            reload()
        }
    }
}
