import ChatCore
import SwiftData
import SwiftUI
import UnalomeDesign

/// Lists personas: create, edit, delete, restore the starters.
struct PersonasView: View {
    let services: AppServices

    @Environment(\.modelContext) private var context
    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @State private var editing: PersonaDraft?
    @State private var errorMessage: String?

    private var store: PersonaStore { PersonaStore(context: context) }

    var body: some View {
        List {
            Section {
                ForEach(personas) { persona in
                    Button {
                        editing = PersonaDraft(persona)
                    } label: {
                        PersonaRow(persona: persona, modelName: modelName(for: persona))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(persona) }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = PersonaDraft(persona) }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(persona) }
                    }
                }
            } footer: {
                Text("A persona's instructions are sent to the model before your messages. Pick one per chat from the model menu.")
            }

            Section {
                Button("Restore starter personas", systemImage: "arrow.counterclockwise") {
                    perform { try store.restoreStarters() }
                }
            } footer: {
                Text("Brings back deleted starters and resets edited ones. Your own personas stay as they are.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(UnalomeColor.background)
        .navigationTitle("Personas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New persona", systemImage: "plus") { editing = PersonaDraft() }
            }
        }
        .overlay {
            if personas.isEmpty {
                ContentUnavailableView(
                    "No personas",
                    systemImage: "person.crop.square",
                    description: Text("Create one, or restore the starters."))
            }
        }
        .sheet(item: $editing) { draft in
            PersonaEditor(draft: draft, modelOptions: services.engineOptions()) { saved in
                save(saved)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func modelName(for persona: Persona) -> String? {
        guard let raw = persona.defaultModel, let choice = EngineChoice(rawValue: raw) else { return nil }
        return services.engineOptions().first { $0.choice == choice }?.title ?? "Model not installed"
    }

    private func save(_ draft: PersonaDraft) {
        perform {
            if let id = draft.id, let persona = store.persona(id: id) {
                persona.name = draft.trimmedName
                persona.systemPrompt = draft.systemPrompt
                persona.temperature = draft.temperature
                persona.defaultModel = draft.defaultModel
                try store.save()
            } else {
                try store.create(
                    name: draft.trimmedName, systemPrompt: draft.systemPrompt,
                    temperature: draft.temperature, defaultModel: draft.defaultModel)
            }
        }
    }

    private func delete(_ persona: Persona) {
        perform { try store.delete(persona) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PersonaRow: View {
    let persona: Persona
    let modelName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(persona.name)
                .unalomeText(.headline)
                .foregroundStyle(UnalomeColor.textPrimary)
            Text(persona.systemPrompt)
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textSecondary)
                .lineLimit(2)
            Text(detail)
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts = ["Temperature \(persona.temperature.formatted(.number.precision(.fractionLength(1))))"]
        if let modelName { parts.append(modelName) }
        return parts.joined(separator: " · ")
    }
}

/// The editable fields of a persona; `id` is nil for a new one.
struct PersonaDraft: Identifiable {
    let id: UUID?
    var name: String
    var systemPrompt: String
    var temperature: Double
    var defaultModel: String?

    init() {
        id = nil
        name = ""
        systemPrompt = ""
        temperature = 0.7
        defaultModel = nil
    }

    init(_ persona: Persona) {
        id = persona.id
        name = persona.name
        systemPrompt = persona.systemPrompt
        temperature = persona.temperature
        defaultModel = persona.defaultModel
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        !trimmedName.isEmpty && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct PersonaEditor: View {
    @State var draft: PersonaDraft
    let modelOptions: [EngineOption]
    let onSave: (PersonaDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("For example: Travel planner", text: $draft.name)
                }
                Section {
                    TextField("What the model should do and how it should answer", text: $draft.systemPrompt, axis: .vertical)
                        .lineLimit(5...14)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Sent to the model as its system prompt. Plain, direct instructions work best with small models.")
                }
                Section {
                    LabeledContent("Temperature") {
                        Text(draft.temperature, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                    }
                    Slider(value: $draft.temperature, in: 0...1.5, step: 0.1) {
                        Text("Temperature")
                    }
                } footer: {
                    Text("Lower is more focused and repeatable; higher is more varied.")
                }
                Section {
                    Picker("Model", selection: $draft.defaultModel) {
                        Text("Keep the current model").tag(String?.none)
                        ForEach(modelOptions) { option in
                            Text(option.title).tag(Optional(option.choice.rawValue))
                        }
                        if let current = draft.defaultModel,
                           !modelOptions.contains(where: { $0.choice.rawValue == current }) {
                            Text("Model not installed").tag(Optional(current))
                        }
                    }
                } footer: {
                    Text("Choosing this persona in a chat switches to this model, if it is installed.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(UnalomeColor.background)
            .navigationTitle(draft.id == nil ? "New persona" : "Edit persona")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }
}
