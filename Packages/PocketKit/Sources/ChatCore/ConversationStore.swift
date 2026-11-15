import Foundation
import SwiftData

/// Creates, renames, deletes, searches and appends to conversations.
/// Works on one `ModelContext`; every mutating call saves before returning.
@MainActor
public struct ConversationStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// A container holding the conversation models plus any `otherModels` (such as installed models).
    /// Tests and previews pass `inMemory: true`.
    public static func makeContainer(
        including otherModels: [any PersistentModel.Type] = [],
        inMemory: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([Conversation.self, Message.self] + otherModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    // MARK: Conversations

    @discardableResult
    public func createConversation() throws -> Conversation {
        let conversation = Conversation()
        context.insert(conversation)
        try context.save()
        return conversation
    }

    /// Sets a user-chosen title. Blank titles are ignored.
    public func rename(_ conversation: Conversation, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed
        conversation.hasAutomaticTitle = false
        try context.save()
    }

    public func delete(_ conversation: Conversation) throws {
        context.delete(conversation)
        try context.save()
    }

    /// Conversations whose title or any message contains `query`, most recent first.
    /// A blank query returns every conversation.
    public func conversations(matching query: String = "") throws -> [Conversation] {
        let descriptor = FetchDescriptor(predicate: Self.searchPredicate(query), sortBy: Self.recentFirst)
        return try context.fetch(descriptor)
    }

    /// Shared with `@Query` in the list screen, so search behaves the same everywhere.
    public static func searchPredicate(_ query: String) -> Predicate<Conversation>? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return #Predicate<Conversation> { conversation in
            conversation.title.localizedStandardContains(query)
                || conversation.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    public static let recentFirst = [SortDescriptor(\Conversation.updatedAt, order: .reverse)]

    // MARK: Messages

    /// Appends a message. The first user message of a conversation with an automatic title
    /// also sets the title.
    @discardableResult
    public func appendMessage(role: ChatRole, text: String, to conversation: Conversation) throws -> Message {
        let existing = conversation.messages
        let position = (existing.map(\.position).max() ?? -1) + 1
        let message = Message(role: role, text: text, position: position)
        context.insert(message)
        message.conversation = conversation

        if role == .user, conversation.hasAutomaticTitle, !existing.contains(where: { $0.role == .user }) {
            conversation.title = Self.automaticTitle(from: text)
        }
        conversation.updatedAt = .now
        try context.save()
        return message
    }

    /// Removes messages, e.g. a reply that is about to be regenerated.
    public func deleteMessages(_ messages: [Message]) throws {
        for message in messages {
            context.delete(message)
        }
        try context.save()
    }

    /// Persists in-place edits such as streamed text.
    public func save() throws {
        try context.save()
    }

    /// The first line of `text`, trimmed and cut at a word boundary to at most `maxLength` characters.
    static func automaticTitle(from text: String, maxLength: Int = 40) -> String {
        let firstLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        guard firstLine.count > maxLength else { return firstLine }

        // One extra character, so a word that ends exactly at the limit is kept.
        let candidate = firstLine.prefix(maxLength + 1)
        guard let wordBoundary = candidate.lastIndex(where: \.isWhitespace) else {
            return firstLine.prefix(maxLength) + "…"
        }
        return candidate[..<wordBoundary].trimmingCharacters(in: .whitespaces) + "…"
    }
}
