import Foundation

/// What the widgets show: the most recent chat, written by the app into the App Group
/// container. The chats themselves stay in the app's own store.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var conversationID: UUID
    public var title: String
    /// The first words of the latest reply, plain text.
    public var replyExcerpt: String
    public var updatedAt: Date

    public init(conversationID: UUID, title: String, replyExcerpt: String, updatedAt: Date) {
        self.conversationID = conversationID
        self.title = title
        self.replyExcerpt = replyExcerpt
        self.updatedAt = updatedAt
    }

    public static let maxExcerptLength = 140

    /// The first non-empty line of a Markdown reply, without the common Markdown marks,
    /// cut at a word boundary.
    public static func excerpt(fromReply text: String, maxLength: Int = maxExcerptLength) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.allSatisfy { "-|:".contains($0) } } ?? ""
        var plain = line
        // Leading block marks: headings, quotes, list bullets.
        while let first = plain.first, "#>*-+".contains(first) {
            plain = String(plain.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for mark in ["**", "__", "`", "*", "_", "~~"] {
            plain = plain.replacingOccurrences(of: mark, with: "")
        }
        plain = plain.trimmingCharacters(in: .whitespaces)
        guard plain.count > maxLength else { return plain }
        let cut = plain.prefix(maxLength)
        if let space = cut.lastIndex(of: " ") {
            return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut + "…"
    }
}

/// Reads and writes the snapshot file. `nil` snapshot means there are no chats.
public struct WidgetSnapshotStore: Sendable {
    /// Shared between the app and its widget extension.
    public static let appGroup = "group.ai.unalome.pocket"
    static let fileName = "widget-snapshot.json"

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName)
    }

    /// The store in the App Group container, or `nil` when the group is not available
    /// (unsigned builds, macOS without the entitlement).
    public static func shared() -> WidgetSnapshotStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map(WidgetSnapshotStore.init(directory:))
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot, or removes the file for `nil`. Returns whether anything changed.
    @discardableResult
    public func write(_ snapshot: WidgetSnapshot?) throws -> Bool {
        // Compare the encoded bytes: ISO 8601 drops fractional seconds, so a decoded copy never
        // equals a fresh snapshot exactly.
        let existing = try? Data(contentsOf: fileURL)
        guard let snapshot else {
            guard existing != nil else { return false }
            try FileManager.default.removeItem(at: fileURL)
            return true
        }
        let data = try Self.encoder.encode(snapshot)
        guard data != existing else { return false }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return true
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
