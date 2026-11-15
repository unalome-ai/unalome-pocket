import Foundation

/// Loads the model catalog: a remotely refreshed copy when one is available, otherwise
/// the last refreshed copy on disk, otherwise the file bundled with the app.
public struct CatalogLoader: Sendable {
    /// Where the public catalog file will live. `nil` until the repo has a public home;
    /// while `nil`, no refresh is attempted and no network request is made.
    public static let defaultRemoteURL: URL? = nil

    private let remoteURL: URL?
    private let cacheFile: URL?
    private let session: URLSession

    public init(remoteURL: URL? = CatalogLoader.defaultRemoteURL, cacheFile: URL?, session: URLSession = .shared) {
        self.remoteURL = remoteURL
        self.cacheFile = cacheFile
        self.session = session
    }

    public enum LoadError: Error {
        case missingBundledCatalog
    }

    /// The catalog shipped inside the app.
    public static func bundled() throws -> Catalog {
        guard let url = bundledFileURL else {
            throw LoadError.missingBundledCatalog
        }
        return try decode(Data(contentsOf: url))
    }

    static var bundledFileURL: URL? {
        Bundle.module.url(forResource: "catalog", withExtension: "json")
    }

    /// The freshest usable catalog. Never throws for network or cache problems; it falls back.
    public func load() async throws -> Catalog {
        if let remote = await fetchRemote() {
            return remote
        }
        if let cacheFile, let data = try? Data(contentsOf: cacheFile), let cached = try? Self.decode(data) {
            return cached
        }
        return try Self.bundled()
    }

    private func fetchRemote() async -> Catalog? {
        guard let remoteURL else { return nil }
        do {
            let (data, response) = try await session.data(from: remoteURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let catalog = try Self.decode(data)
            if let cacheFile {
                try? FileManager.default.createDirectory(
                    at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheFile, options: .atomic)
            }
            return catalog
        } catch {
            return nil
        }
    }

    /// Decodes and checks a catalog file. Files with an unknown version or no models are rejected.
    static func decode(_ data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.version == Catalog.supportedVersion, !catalog.models.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported catalog"))
        }
        return catalog
    }
}
