import AppIntents

/// Siri and Shortcuts phrases. Each opens the app, which answers on this device.
struct PocketShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPocketIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask",
            systemImageName: "text.bubble")
        AppShortcut(
            intent: NewChatIntent(),
            phrases: ["New chat in \(.applicationName)"],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil")
        AppShortcut(
            intent: AskByVoiceIntent(),
            phrases: ["Talk to \(.applicationName)"],
            shortTitle: "Ask by Voice",
            systemImageName: "mic")
    }
}
