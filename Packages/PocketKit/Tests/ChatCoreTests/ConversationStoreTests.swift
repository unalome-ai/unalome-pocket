import Foundation
import SwiftData
import Testing
@testable import ChatCore

@MainActor
struct ConversationStoreTests {
    // The container must outlive the context the store uses.
    private let container: ModelContainer
    private let store: ConversationStore

    init() throws {
        container = try ConversationStore.makeContainer(inMemory: true)
        store = ConversationStore(context: container.mainContext)
    }

    @Test func createAppendAndOrder() throws {
        let conversation = try store.createConversation()
        try store.appendMessage(role: .user, text: "One", to: conversation)
        try store.appendMessage(role: .assistant, text: "Two", to: conversation)
        try store.appendMessage(role: .user, text: "Three", to: conversation)

        #expect(conversation.orderedMessages.map(\.text) == ["One", "Two", "Three"])
        #expect(conversation.orderedMessages.map(\.position) == [0, 1, 2])
        #expect(try store.conversations().count == 1)
    }

    @Test func firstUserMessageSetsTitleOnce() throws {
        let conversation = try store.createConversation()
        #expect(conversation.displayTitle == "New chat")

        try store.appendMessage(role: .user, text: "  Plan a trip to Lisbon\nwith kids  ", to: conversation)
        #expect(conversation.title == "Plan a trip to Lisbon")

        try store.appendMessage(role: .user, text: "Something else", to: conversation)
        #expect(conversation.title == "Plan a trip to Lisbon")
    }

    @Test func renameStopsAutomaticTitles() throws {
        let conversation = try store.createConversation()
        try store.rename(conversation, to: "  Holidays ")
        #expect(conversation.title == "Holidays")
        #expect(!conversation.hasAutomaticTitle)

        try store.appendMessage(role: .user, text: "Plan a trip", to: conversation)
        #expect(conversation.title == "Holidays")

        try store.rename(conversation, to: "   ")
        #expect(conversation.title == "Holidays")
    }

    @Test func deleteRemovesConversationAndMessages() throws {
        let conversation = try store.createConversation()
        try store.appendMessage(role: .user, text: "Hi", to: conversation)
        try store.appendMessage(role: .assistant, text: "Hello", to: conversation)

        try store.delete(conversation)

        #expect(try store.conversations().isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Message>()) == 0)
    }

    @Test func searchMatchesTitleAndMessageText() throws {
        let trip = try store.createConversation()
        try store.appendMessage(role: .user, text: "Plan a trip to Lisbon", to: trip)
        try store.appendMessage(role: .assistant, text: "Start at the Alfama district.", to: trip)
        let recipe = try store.createConversation()
        try store.appendMessage(role: .user, text: "Bread recipe", to: recipe)

        #expect(try store.conversations(matching: "lisbon").map(\.id) == [trip.id])
        #expect(try store.conversations(matching: "ALFAMA").map(\.id) == [trip.id])
        #expect(try store.conversations(matching: "bread").map(\.id) == [recipe.id])
        #expect(try store.conversations(matching: "pasta").isEmpty)
        // Blank query: everything, most recently updated first.
        #expect(try store.conversations(matching: "  ").map(\.id) == [recipe.id, trip.id])
    }

    @Test func deleteMessagesRemovesOnlyThose() throws {
        let conversation = try store.createConversation()
        try store.appendMessage(role: .user, text: "Hi", to: conversation)
        let reply = try store.appendMessage(role: .assistant, text: "Hello", to: conversation)

        try store.deleteMessages([reply])

        #expect(conversation.orderedMessages.map(\.text) == ["Hi"])
    }

    @Test(arguments: [
        ("Short title", "Short title"),
        ("", ""),
        ("First line\nSecond line", "First line"),
        ("This is a rather long first message that keeps going", "This is a rather long first message that…"),
        (String(repeating: "x", count: 50), String(repeating: "x", count: 40) + "…"),
    ])
    func automaticTitle(input: String, expected: String) {
        #expect(ConversationStore.automaticTitle(from: input) == expected)
    }
}
