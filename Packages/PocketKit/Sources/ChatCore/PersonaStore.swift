import Foundation
import SwiftData

/// Personas: the built-in starters, plus the user's own.
@MainActor
public struct PersonaStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public struct Starter: Sendable {
        public var key: String
        public var name: String
        public var prompt: String
        public var temperature: Double
    }

    /// Plain, useful starters. No companion or role-play characters.
    public static let starters: [Starter] = [
        Starter(
            key: "assistant", name: "Assistant",
            prompt: """
                You are a helpful assistant running entirely on the user's device. Answer clearly and \
                directly. Prefer short answers; use lists or tables when they make things easier to scan. \
                If you are not sure about something, say so.
                """,
            temperature: 0.7),
        Starter(
            key: "editor", name: "Writing editor",
            prompt: """
                You are a careful editor. Improve the user's text for clarity, grammar and flow while \
                keeping their meaning, tone and language. Return the edited text first, then a short list \
                of the main changes. Do not add new content unless asked.
                """,
            temperature: 0.4),
        Starter(
            key: "explainer", name: "Explainer",
            prompt: """
                You explain things simply. Start with a one-sentence answer, then build up step by step \
                with plain words and a concrete example. Define any technical term the first time you \
                use it. Check understanding by ending with one short question the user could try.
                """,
            temperature: 0.6),
        Starter(
            key: "coder", name: "Coder",
            prompt: """
                You are an experienced software engineer. Give working, idiomatic code in fenced code \
                blocks with the language named. Keep explanations brief and focused on why. Point out \
                edge cases and anything the user should test.
                """,
            temperature: 0.2),
    ]

    public func all() throws -> [Persona] {
        try context.fetch(FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    public func persona(id: UUID?) -> Persona? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Persona>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Adds the starters on first launch (when there are no personas at all).
    public func seedIfEmpty() throws {
        guard try context.fetchCount(FetchDescriptor<Persona>()) == 0 else { return }
        try restoreStarters()
    }

    /// Adds the starters once per install, so deleting all of them sticks.
    public func seedOnce(defaults: UserDefaults) throws {
        let key = "personasSeeded"
        guard !defaults.bool(forKey: key) else { return }
        try seedIfEmpty()
        defaults.set(true, forKey: key)
    }

    /// Re-creates missing starters and resets edited ones to their original text.
    public func restoreStarters() throws {
        let existing = try all()
        let base = Date.now
        for (index, starter) in Self.starters.enumerated() {
            if let persona = existing.first(where: { $0.starterKey == starter.key }) {
                persona.name = starter.name
                persona.systemPrompt = starter.prompt
                persona.temperature = starter.temperature
            } else {
                // Keep the starters in their listed order, before anything the user creates later.
                context.insert(
                    Persona(
                        name: starter.name, systemPrompt: starter.prompt, temperature: starter.temperature,
                        starterKey: starter.key, createdAt: base.addingTimeInterval(Double(index) - 1_000_000)))
            }
        }
        try context.save()
    }

    @discardableResult
    public func create(name: String, systemPrompt: String, temperature: Double, defaultModel: String?) throws -> Persona {
        let persona = Persona(name: name, systemPrompt: systemPrompt, temperature: temperature, defaultModel: defaultModel)
        context.insert(persona)
        try context.save()
        return persona
    }

    public func delete(_ persona: Persona) throws {
        context.delete(persona)
        try context.save()
    }

    public func save() throws {
        try context.save()
    }
}
