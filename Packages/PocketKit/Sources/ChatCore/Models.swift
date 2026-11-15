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
    /// The persona whose prompt and temperature this chat uses; `nil` for none.
    /// An id rather than a relationship, so deleting a persona leaves chats intact.
    public var personaID: UUID?

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
    /// Attached images, as file names in the `AttachmentStore`.
    public var attachmentNames: [String] = []
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

    /// What the engine sees: the text (and images) only. Reasoning stays out of the history.
    public func turn(attachments: AttachmentStore?) -> ChatTurn {
        ChatTurn(role: role, text: text, images: attachments.map { store in attachmentNames.map(store.url(for:)) } ?? [])
    }

    /// The text-only turn.
    public var turn: ChatTurn {
        ChatTurn(role: role, text: text)
    }
}

/// A reusable set of instructions and settings for a chat ("Writing editor", "Coder" …).
@Model
public final class Persona {
    @Attribute(.unique) public var id: UUID
    public var name: String
    /// Sent to the model as the system turn.
    public var systemPrompt: String
    public var temperature: Double
    /// `EngineChoice.rawValue` of the model to switch to when the persona is picked, if any.
    public var defaultModel: String?
    /// Set for the built-in starters, so they can be restored.
    public var starterKey: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, systemPrompt: String, temperature: Double = 0.7,
        defaultModel: String? = nil, starterKey: String? = nil, createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.defaultModel = defaultModel
        self.starterKey = starterKey
        self.createdAt = createdAt
    }
}
