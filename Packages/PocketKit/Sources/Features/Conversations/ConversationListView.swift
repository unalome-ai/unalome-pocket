import ChatCore
import SwiftData
import SwiftUI
import UnalomeDesign

/// The searchable list of saved conversations. The sidebar on iPad and Mac.
struct ConversationListView: View {
    @Binding var selection: Conversation?
    let store: ConversationStore

    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        ConversationRows(
            query: searchText,
            selection: $selection,
            onRename: { conversation in
                renameText = conversation.title
                renaming = conversation
            },
            onDelete: delete
        )
        .searchable(text: $searchText, prompt: "Search chats")
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New chat", systemImage: "square.and.pencil", action: newChat)
            }
        }
        .alert("Rename chat", isPresented: isPresented($renaming)) {
            TextField("Title", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: isPresented($errorMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func newChat() {
        perform { selection = try store.createConversation() }
    }

    private func rename() {
        guard let conversation = renaming else { return }
        perform { try store.rename(conversation, to: renameText) }
    }

    private func delete(_ conversation: Conversation) {
        if selection?.id == conversation.id {
            selection = nil
        }
        perform { try store.delete(conversation) }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}

/// Split out so `@Query` can be rebuilt with the current search text.
private struct ConversationRows: View {
    @Query private var conversations: [Conversation]
    @Binding var selection: Conversation?
    let query: String
    let onRename: (Conversation) -> Void
    let onDelete: (Conversation) -> Void

    init(
        query: String,
        selection: Binding<Conversation?>,
        onRename: @escaping (Conversation) -> Void,
        onDelete: @escaping (Conversation) -> Void
    ) {
        _conversations = Query(
            filter: ConversationStore.searchPredicate(query),
            sort: ConversationStore.recentFirst
        )
        _selection = selection
        self.query = query
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRow(conversation: conversation)
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete(conversation) }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { onRename(conversation) }
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete(conversation) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(UnalomeColor.background)
        .overlay {
            if conversations.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start one with the New chat button.")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.displayTitle)
                .unalomeText(.headline)
                .foregroundStyle(UnalomeColor.textPrimary)
                .lineLimit(2)
            Text(conversation.updatedAt, format: .relative(presentation: .named))
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
        }
        .padding(.vertical, 4)
    }
}
