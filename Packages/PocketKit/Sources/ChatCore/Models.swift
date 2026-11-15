import Foundation
import SwiftData

@Model
public final class Conversation {
    @Attribute(.unique) public var id: UUID
    /// Empty until the first user message gives it an automatic title.
    public var title: String
    /// `false` once the user renames the conversation; automatic titles then stop.
    public var hasAutomaticTitle: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Whether replies in this chat may reason first (for models that support it). Off by default.
    public var isThinkingEnabled: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message] = []

    public init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.title = ""
        self.hasAutomaticTitle = true
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// The title to show; untitled conversations read "New chat".
    public var displayTitle: String {
        title.isEmpty ? "New chat" : title
    }

    /// Messages in the order they were added. SwiftData does not keep to-many order.
    public var orderedMessages: [Message] {
        messages.sorted { $0.position < $1.position }
    }
}

@Model
public final class Message {
    @Attribute(.unique) public var id: UUID
    public var role: ChatRole
    public var text: String
    /// The model's reasoning before `text`, if it showed any. Never sent back to the model.
    public var reasoning: String = ""
    /// How long the model reasoned, once it started answering or stopped.
    public var reasoningSeconds: Double?
    /// The reply was cut off at the length limit and can be continued.
    public var stoppedAtLengthLimit: Bool = false
    public var createdAt: Date
    /// Insertion order within the conversation.
    public var position: Int
    public var conversation: Conversation?

    public init(id: UUID = UUID(), role: ChatRole, text: String, position: Int, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.position = position
        self.createdAt = createdAt
    }

    /// What the engine sees: the text only. Reasoning stays out of the history.
    public var turn: ChatTurn {
        ChatTurn(role: role, text: text)
    }
}
