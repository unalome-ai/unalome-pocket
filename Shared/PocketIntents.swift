import AppIntents
import PocketShared

// Compiled into the app and the widget extension. Every intent opens the app, which answers:
// an extension has too little memory to run a model.

/// Opens a new chat.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens Unalome Pocket on a new chat.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        RouteInbox.shared.post(.newChat)
        return .result()
    }
}

/// Opens a new chat and starts listening.
struct AskByVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask by Voice"
    static let description = IntentDescription(
        "Opens Unalome Pocket on a new chat and starts on-device dictation.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        RouteInbox.shared.post(.voice)
        return .result()
    }
}

/// Opens a new chat with a question. The app answers it with the selected model.
struct AskPocketIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Unalome Pocket"
    static let description = IntentDescription(
        "Opens Unalome Pocket and asks the selected model your question, on this device.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        RouteInbox.shared.post(.ask(question))
        return .result()
    }
}
