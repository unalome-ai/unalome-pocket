import ChatCore
import PocketShared
import SwiftData
import SwiftUI
import UnalomeDesign
#if os(iOS)
import UIKit
#endif

/// The app's root: onboarding on first run, then conversations in a sidebar (iPad, Mac)
/// or a stack (iPhone) with the chat as the detail.
/// Expects a model container from `ConversationStore.makeContainer` in the environment.
public struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var selection: Conversation?
    @State private var errorMessage: String?
    @State private var isShowingModels = false
    @State private var isShowingPersonas = false
    @State private var isShowingAbout = false
    /// A start action waiting for its chat to appear.
    @State private var pendingStart: (id: UUID, action: ChatStartAction)?
    @State private var inbox = RouteInbox.shared
    @State private var commands = CommandCenter.shared
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        Group {
            if services.preferences.hasCompletedOnboarding {
                conversations
            } else {
                OnboardingView(services: services) {
                    services.preferences.hasCompletedOnboarding = true
                }
            }
        }
        .tint(UnalomeColor.emerald)
        .preferredColorScheme(.dark)
        .task { await services.library.refreshCatalog() }
        .task { prepareStores() }
        // Routes wait until onboarding is done, then open their chat.
        .onOpenURL { url in
            if let route = AppRoute(url: url) { inbox.post(route) }
        }
        .onChange(of: inbox.pending, initial: true) { _, _ in applyPendingRoute() }
        .onChange(of: services.preferences.hasCompletedOnboarding) { _, _ in applyPendingRoute() }
        .modifier(KeepAwakeWhile(isActive: services.library.isDownloading))
    }

    private var conversations: some View {
        let store = ConversationStore(context: context, attachments: services.attachments)
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(selection: $selection, store: store) {
                services.widgetSnapshots?.publish(from: store)
            }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("Models", systemImage: "cpu") { isShowingModels = true }
                    }
                    ToolbarItem(placement: .navigation) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Personas", systemImage: "person.crop.square") { isShowingPersonas = true }
                            Button("About & Settings", systemImage: "info.circle") { isShowingAbout = true }
                        }
                    }
                }
        } detail: {
            if let selection {
                ChatView(
                    conversation: selection, store: store, services: services,
                    startAction: pendingStart?.id == selection.id ? pendingStart?.action : nil,
                    onStartActionHandled: { pendingStart = nil }
                )
                .id(selection.id)
            } else {
                NoChatSelectedView {
                    do {
                        selection = try store.createConversation()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // ⌘F: show the list (the sidebar, or the list itself in compact width) and its search field.
        .onChange(of: commands.searchRequest) { _, _ in
            if sizeClass == .compact { selection = nil } else { columnVisibility = .all }
        }
        .onChange(of: commands.settingsRequest) { _, _ in isShowingAbout = true }
        .sheet(isPresented: $isShowingModels) {
            NavigationStack {
                ModelsView(services: services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingModels = false }
                        }
                    }
            }
            .sheetFrame()
        }
        .sheet(isPresented: $isShowingPersonas) {
            NavigationStack {
                PersonasView(services: services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingPersonas = false }
                        }
                    }
            }
            .sheetFrame()
        }
        .sheet(isPresented: $isShowingAbout) {
            NavigationStack {
                AboutView(services: services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingAbout = false }
                        }
                    }
            }
            .sheetFrame()
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
}

extension RootView {
    /// Opens the chat a route asks for. Waits while onboarding is showing.
    private func applyPendingRoute() {
        guard services.preferences.hasCompletedOnboarding, let route = inbox.take() else { return }
        let store = ConversationStore(context: context, attachments: services.attachments)
        do {
            switch route {
            case .newChat:
                selection = try store.createConversation()
            case .voice:
                let chat = try store.createConversation()
                pendingStart = (chat.id, .listen)
                selection = chat
            case .ask(let question):
                let chat = try store.createConversation()
                pendingStart = (chat.id, .ask(question))
                selection = chat
            case .conversation(let id):
                // A chat deleted since the widget last refreshed: stay where we are.
                if let chat = try store.conversations().first(where: { $0.id == id }) {
                    selection = chat
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds the starter personas on first launch and deletes images no message uses.
    private func prepareStores() {
        do {
            try PersonaStore(context: context).seedOnce(defaults: services.preferences.defaults)
            let store = ConversationStore(context: context, attachments: services.attachments)
            try store.removeUnreferencedAttachments()
            services.widgetSnapshots?.publish(from: store)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Detail placeholder on iPad and Mac when no conversation is selected.
private struct NoChatSelectedView: View {
    let newChat: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                Text("Your AI.")
                    .foregroundStyle(UnalomeColor.textPrimary)
                GradientText("In your pocket.")
            }
            .unalomeText(.display)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Button("New chat", action: newChat)
                .buttonStyle(.unalomePrimary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UnalomeColor.background)
    }
}

/// Keeps the screen on while `isActive` (a model download), so iOS does not lock and suspend
/// the app halfway; restores the previous setting afterwards.
private struct KeepAwakeWhile: ViewModifier {
    let isActive: Bool
    @State private var previous: Bool?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                #if os(iOS)
                if active, previous == nil {
                    previous = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                } else if !active, let previous {
                    UIApplication.shared.isIdleTimerDisabled = previous
                    self.previous = nil
                }
                #endif
            }
    }
}

extension View {
    /// Sheets on Mac open at a usable size instead of shrinking to their content.
    func sheetFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 520, idealWidth: 620, minHeight: 560, idealHeight: 720)
        #else
        self
        #endif
    }
}
