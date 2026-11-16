import ChatCore
import Foundation
import PocketShared
import SwiftData
import Testing
@testable import Features

@MainActor
struct WidgetSnapshotPublisherTests {
    @Test func publishesTheLatestChatAndClearsWhenNoneAreLeft() throws {
        let container = try ConversationStore.makeContainer(inMemory: true)
        let store = ConversationStore(context: container.mainContext)
        let directory = FileManager.default.temporaryDirectory.appending(path: "Publisher-\(UUID().uuidString)")
        let snapshots = WidgetSnapshotStore(directory: directory)
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(store: snapshots) { reloads += 1 }

        let older = try store.createConversation()
        try store.appendMessage(role: .user, text: "Old question", to: older)
        let newer = try store.createConversation()
        try store.appendMessage(role: .user, text: "Tell me about the Moon", to: newer)
        try store.appendMessage(role: .assistant, text: "**The Moon** is tidally locked.\n\nMore.", to: newer)
        try store.appendMessage(role: .assistant, text: "", to: newer)  // a reply still streaming
        newer.updatedAt = .now.addingTimeInterval(10)

        publisher.publish(from: store)
        let snapshot = try #require(snapshots.read())
        #expect(snapshot.conversationID == newer.id)
        #expect(snapshot.title == "Tell me about the Moon")
        #expect(snapshot.replyExcerpt == "The Moon is tidally locked.")
        #expect(reloads == 1)

        publisher.publish(from: store)
        #expect(reloads == 1, "nothing changed, so the widgets are not reloaded")

        try store.delete(newer)
        try store.delete(older)
        publisher.publish(from: store)
        #expect(snapshots.read() == nil)
        #expect(reloads == 2)
    }
}
