import PocketShared
import SwiftUI

/// Requests from the menu bar and keyboard shortcuts that the root view carries out.
@MainActor
@Observable
public final class CommandCenter {
    public static let shared = CommandCenter()

    /// Bumped by Search Chats; the conversation list focuses its search field.
    public private(set) var searchRequest = 0
    /// Bumped by Settings on iPad; the root view opens About & Settings.
    public private(set) var settingsRequest = 0

    public func requestSearch() { searchRequest += 1 }
    public func requestSettings() { settingsRequest += 1 }
}

/// The menu bar on Mac and the keyboard-shortcut menu on iPad: New Chat (⌘N), Search Chats (⌘F),
/// Stop Generating (⌘. or Esc in the composer) and, on iPad, Settings (⌘,). On Mac, ⌘, opens the
/// Settings window.
public struct PocketCommands: Commands {
    @FocusedValue(\.chatModel) private var chat

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { RouteInbox.shared.post(.newChat) }
                .keyboardShortcut("n")
        }
        #if os(iOS)
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { CommandCenter.shared.requestSettings() }
                .keyboardShortcut(",")
        }
        #endif
        CommandMenu("Chat") {
            Button("Search Chats") { CommandCenter.shared.requestSearch() }
                .keyboardShortcut("f")
            Divider()
            Button("Stop Generating") { chat?.stop() }
                .keyboardShortcut(".")
                .disabled(chat?.isGenerating != true)
            Button("Regenerate Reply") { chat?.regenerate() }
                .keyboardShortcut("r")
                .disabled(chat?.canRegenerate != true)
            Button("Continue Reply") { chat?.continueReply() }
                .disabled(chat?.canContinue != true)
        }
    }
}
