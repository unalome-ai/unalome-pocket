import Foundation
import ModelCatalog

/// Addresses and links the app shows. One place each, so they are easy to confirm.
public enum AppLinks {
    /// Where "Report this response" emails go.
    public static let supportEmail = "support@unalome.ai"
    /// The app's source code.
    public static let sourceCode = URL(string: "https://github.com/unalome-ai/unalome-pocket")!
    public static let website = URL(string: "https://unalome.ai")!
}

/// The app's version, from its Info.plist.
public enum AppVersion {
    public static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// "0.1.0 (1)".
    public static var display: String { "\(marketing) (\(build))" }
}

/// Device wording for the device the app runs on: "this iPhone", "this iPad", "this Mac".
public enum DeviceWording {
    public static var kind: DeviceProfile.Kind { DeviceProfile.currentKind }
    public static var thisDevice: String { kind.thisDevice }
    public static var name: String { kind.name }
}

/// A prefilled email reporting a model reply (App Review guideline 1.2). Nothing is sent by the
/// app: the user's mail app opens with the draft, and the user decides whether to send it.
public struct ReportEmail: Equatable, Sendable {
    public var recipient: String
    public var subject: String
    public var body: String

    /// Each quoted text is cut to this many characters, so the link stays short enough for mail apps.
    static let maxQuoteLength = 1500

    public init(question: String?, reply: String, modelName: String, appVersion: String, deviceName: String,
                recipient: String = AppLinks.supportEmail) {
        self.recipient = recipient
        subject = "Report a response from Unalome Pocket"
        var lines = [
            "What is wrong with this response? (optional)",
            "",
            "",
            "---",
            "Model: \(modelName)",
            "App: Unalome Pocket \(appVersion) on \(deviceName)",
        ]
        if let question, !question.isEmpty {
            lines += ["", "My message:", Self.quote(question)]
        }
        lines += ["", "The response:", Self.quote(reply)]
        body = lines.joined(separator: "\n")
    }

    static func quote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxQuoteLength else { return trimmed }
        return String(trimmed.prefix(maxQuoteLength)) + "… [shortened]"
    }

    /// A `mailto:` link with the subject and body filled in.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // `URLComponents` leaves "+" as is; some mail apps read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// What the confirmation says before the mail app opens.
    public static let explanation =
        "This opens an email to Unalome with this response and the message it answered. Nothing is sent unless you send the email yourself."
}
