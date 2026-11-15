import Foundation
import Testing
@testable import ModelCatalog

struct CatalogTests {
    @Test func bundledCatalogIsValid() throws {
        let catalog = try CatalogLoader.bundled()
        #expect(catalog.version == Catalog.supportedVersion)
        #expect(!catalog.models.isEmpty)
        #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
        #expect(Set(catalog.models.map(\.qualityRank)).count == catalog.models.count)
        for entry in catalog.models {
            #expect(RepoID.isValid(entry.id), "\(entry.id)")
            #expect(entry.revision.count == 40 && entry.revision.allSatisfy(\.isHexDigit), "\(entry.id)")
            #expect(entry.downloadSizeBytes > 0)
            #expect(entry.minimumMemoryBytes > entry.downloadSizeBytes)
            #expect(entry.minimumMemoryIsEstimate, "Memory figures stay estimates until measured on a device")
            #expect(entry.license.url != nil, "\(entry.id) needs a licence link")
            #expect(!entry.license.name.isEmpty)
            #expect(!entry.goodFor.isEmpty)
            #expect(entry.isVerified)
        }
    }

    /// `catalog/catalog.json` at the repo root is the public copy; the app bundles the same file.
    @Test func repoCatalogMatchesBundledCatalog() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ModelCatalogTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PocketKit
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()
        let repoCopy = try Data(contentsOf: repoRoot.appending(path: "catalog/catalog.json"))
        let bundledURL = try #require(CatalogLoader.bundledFileURL)
        #expect(repoCopy == (try Data(contentsOf: bundledURL)))
    }

    @Test func noRemoteURLIsConfigured() {
        #expect(CatalogLoader.defaultRemoteURL == nil)
    }

    @Test func memoryEstimateAddsActivationsAndRuntime() {
        let weights: Int64 = 1_000_000_000
        #expect(MemoryEstimate.bytes(forWeights: weights) == weights + weights / 5 + 512 * 1024 * 1024)
    }

    @Test func rejectsUnknownCatalogVersion() {
        let data = Data(#"{"version": 99, "models": []}"#.utf8)
        #expect(throws: (any Error).self) { try CatalogLoader.decode(data) }
    }

    @Test func withoutRemoteOrCacheLoadsBundledCatalog() async throws {
        let loader = CatalogLoader(remoteURL: nil, cacheFile: nil)
        #expect(try await loader.load() == CatalogLoader.bundled())
    }

    @Test func remoteCatalogIsUsedAndCached() async throws {
        var remote = try CatalogLoader.bundled()
        remote.models = Array(remote.models.prefix(1))
        let body = try JSONEncoder().encode(remote)
        let server = StubServer { _ in .init(status: 200, body: body) }
        let cache = try temporaryDirectory().appending(path: "catalog-cache.json")
        let loader = CatalogLoader(
            remoteURL: server.baseURL.appending(path: "catalog.json"), cacheFile: cache, session: server.session())

        #expect(try await loader.load() == remote)
        #expect(FileManager.default.fileExists(atPath: cache.path))

        // When the remote fails, the cached copy is used.
        let failing = StubServer { _ in .init(status: 500, body: Data()) }
        let offline = CatalogLoader(
            remoteURL: failing.baseURL.appending(path: "catalog.json"), cacheFile: cache, session: failing.session())
        #expect(try await offline.load() == remote)
    }

    @Test func invalidRemoteCatalogFallsBackToBundled() async throws {
        let server = StubServer { _ in .json(#"{"version": 1, "models": []}"#) }
        let loader = CatalogLoader(
            remoteURL: server.baseURL.appending(path: "catalog.json"), cacheFile: nil, session: server.session())
        #expect(try await loader.load() == CatalogLoader.bundled())
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "PocketKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
