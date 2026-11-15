import ChatCore
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
        .modifier(KeepAwakeWhile(isActive: services.library.isDownloading))
    }

    private var conversations: some View {
        let store = ConversationStore(context: context)
        return NavigationSplitView {
            ConversationListView(selection: $selection, store: store)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("Models", systemImage: "cpu") { isShowingModels = true }
                    }
                }
        } detail: {
            if let selection {
                ChatView(conversation: selection, store: store, services: services)
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
        .sheet(isPresented: $isShowingModels) {
            NavigationStack {
                ModelsView(services: services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingModels = false }
                        }
                    }
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
