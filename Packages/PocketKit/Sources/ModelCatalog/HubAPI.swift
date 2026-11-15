import Foundation

/// Read-only access to the public Hugging Face API. No account, no token, no personal data.
public struct HubAPI: Sendable {
    public static let defaultHost: URL = {
        guard let url = URL(string: "https://huggingface.co") else {
            preconditionFailure("The Hugging Face host literal is not a valid URL.")
        }
        return url
    }()

    private let host: URL
    private let session: URLSession

    public init(host: URL = HubAPI.defaultHost, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    public enum HubError: LocalizedError, Equatable {
        case invalidRepoID
        case notFound
        case gated
        case badResponse(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidRepoID: "Use the form organisation/model, for example mlx-community/Qwen3.5-0.8B-4bit."
            case .notFound: "No public model with that ID was found on Hugging Face."
            case .gated: "This model needs a Hugging Face account to download, which this app does not use."
            case .badResponse(let status): "Hugging Face answered with an unexpected status (\(status))."
            }
        }
    }

    /// Repo metadata at a revision (default: the main branch), including file sizes.
    public func modelInfo(repoID: String, revision: String? = nil) async throws -> HubModelInfo {
        guard RepoID.isValid(repoID) else { throw HubError.invalidRepoID }
        var url = host.appending(path: "api/models").appending(path: repoID)
        if let revision {
            url = url.appending(path: "revision").appending(path: revision)
        }
        url.append(queryItems: [URLQueryItem(name: "blobs", value: "true")])
        var request = URLRequest(url: url)
        request.setValue("UnalomePocket", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 404: throw HubError.notFound
        default: throw HubError.badResponse(status)
        }
        return try JSONDecoder().decode(HubModelInfo.self, from: data)
    }

    /// Download URL of one file at a pinned revision.
    public func fileURL(repoID: String, revision: String, path: String) -> URL {
        host.appending(path: repoID).appending(path: "resolve").appending(path: revision).appending(path: path)
    }
}

/// `organisation/model`, as Hugging Face allows them.
public enum RepoID {
    public static func isValid(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            (1...96).contains(part.count)
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
                && !part.hasPrefix(".") && !part.contains("..")
        }
    }
}

/// The parts of `GET /api/models/{id}` the app uses.
public struct HubModelInfo: Decodable, Sendable, Equatable {
    public struct File: Decodable, Sendable, Equatable {
        public var path: String
        public var size: Int64?

        private enum CodingKeys: String, CodingKey {
            case path = "rfilename"
            case size
        }

        public init(path: String, size: Int64?) {
            self.path = path
            self.size = size
        }
    }

    public struct CardData: Decodable, Sendable, Equatable {
        public var license: String?
        public var licenseName: String?
        public var licenseLink: String?

        private enum CodingKeys: String, CodingKey {
            case license
            case licenseName = "license_name"
            case licenseLink = "license_link"
        }
    }

    /// The commit SHA the metadata describes.
    public var sha: String
    public var files: [File]
    public var tags: [String]
    public var libraryName: String?
    public var cardData: CardData?
    /// `false`, or a string such as `"manual"` / `"auto"` for gated repos.
    public var isGated: Bool

    private enum CodingKeys: String, CodingKey {
        case sha
        case files = "siblings"
        case tags
        case libraryName = "library_name"
        case cardData
        case gated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha = try container.decode(String.self, forKey: .sha)
        files = try container.decodeIfPresent([File].self, forKey: .files) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        cardData = try container.decodeIfPresent(CardData.self, forKey: .cardData)
        if let flag = try? container.decode(Bool.self, forKey: .gated) {
            isGated = flag
        } else {
            isGated = (try? container.decode(String.self, forKey: .gated)) != nil
        }
    }

    /// Files the app downloads: weights, JSON configs and tokenizer, chat template.
    /// The same patterns `mlx-swift-lm` uses when it downloads by itself.
    public var modelFiles: [File] {
        files.filter { file in
            [".safetensors", ".json", ".jinja"].contains { file.path.hasSuffix($0) }
        }
    }

    public var modelFilesSize: Int64 {
        modelFiles.reduce(0) { $0 + ($1.size ?? 0) }
    }

    public var isMLX: Bool {
        libraryName == "mlx" || tags.contains("mlx")
    }

    /// A readable licence name from the model card, if it has one.
    public var licenseName: String? {
        guard let cardData else { return nil }
        if let name = cardData.licenseName, cardData.license == "other" || cardData.license == nil {
            return name
        }
        return cardData.license
    }
}
