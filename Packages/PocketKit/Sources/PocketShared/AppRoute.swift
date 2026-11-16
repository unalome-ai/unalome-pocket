import Foundation

/// Where an outside entry point (Siri, Shortcuts, a widget, a control, a URL) sends the app.
/// The app opens, then `RootView` acts on the route; extensions never run the model.
public enum AppRoute: Equatable, Sendable {
    /// A new, empty chat.
    case newChat
    /// A new chat with dictation already listening.
    case voice
    /// A new chat that sends `question` with the selected model.
    case ask(String)
    /// An existing chat.
    case conversation(UUID)

    /// The app's URL scheme, registered in the app's Info.plist.
    public static let scheme = "unalomepocket"

    /// `unalomepocket://new`, `unalomepocket://voice`, `unalomepocket://ask?q=…`,
    /// `unalomepocket://conversation/<uuid>`.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .newChat:
            components.host = "new"
        case .voice:
            components.host = "voice"
        case .ask(let question):
            components.host = "ask"
            components.queryItems = [URLQueryItem(name: "q", value: question)]
        case .conversation(let id):
            components.host = "conversation"
            components.path = "/" + id.uuidString
        }
        // Every component above is valid, so this cannot fail; fall back to the bare scheme.
        return components.url ?? URL(string: "\(Self.scheme)://new")!
    }

    /// Parses a URL in the app's scheme. Anything else, or a malformed route, returns `nil`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        switch components.host?.lowercased() {
        case "new":
            self = .newChat
        case "voice":
            self = .voice
        case "ask":
            let question = components.queryItems?.first { $0.name == "q" }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self = question.isEmpty ? .newChat : .ask(question)
        case "conversation":
            let idText = components.path.split(separator: "/").first.map(String.init) ?? ""
            guard let id = UUID(uuidString: idText) else { return nil }
            self = .conversation(id)
        default:
            return nil
        }
    }
}

/// Hands routes from App Intents (which run in the app process) to the UI.
///
/// Intents post here; `RootView` takes the route when it is ready, so a route that arrives
/// during launch or onboarding is not lost.
@MainActor
@Observable
public final class RouteInbox {
    public static let shared = RouteInbox()

    public private(set) var pending: AppRoute?

    public init() {}

    public func post(_ route: AppRoute) {
        pending = route
    }

    /// Returns the pending route and clears it.
    public func take() -> AppRoute? {
        defer { pending = nil }
        return pending
    }
}
