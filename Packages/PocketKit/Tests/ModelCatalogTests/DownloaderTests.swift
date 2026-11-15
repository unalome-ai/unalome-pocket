import Foundation
import Synchronization
import Testing
@testable import ModelCatalog

/// A fake Hugging Face repo with two files, served by `StubServer`.
private struct FakeRepo {
    static let repoID = "test-org/Fake-4bit"
    static let revision = "0123456789abcdef0123456789abcdef01234567"
    static let config = Data(#"{"model_type": "fake"}"#.utf8)
    static let weights = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    static var entry: CatalogEntry {
        CatalogEntry(
            id: repoID, displayName: "Fake", revision: revision,
            downloadSizeBytes: Int64(config.count + weights.count), minimumMemoryBytes: 1,
            minimumMemoryIsEstimate: true, supportsVision: false,
            license: .init(name: "Test", url: nil), goodFor: "Tests", tier: .small, qualityRank: 1)
    }

    static func info(extraFile: String? = nil, weightsSize: Int? = nil) -> String {
        let extra = extraFile.map { #", {"rfilename": "\#($0)", "size": 1}"# } ?? ""
        return """
            {"sha": "\(revision)", "tags": ["mlx"], "siblings": [
              {"rfilename": "config.json", "size": \(config.count)},
              {"rfilename": "model.safetensors", "size": \(weightsSize ?? weights.count)},
              {"rfilename": "README.md", "size": 10}\(extra)
            ]}
            """
    }

    /// Serves the metadata and both files; `weights` can be customised per test.
    static func server(
        info: String = info(),
        weightsResponse: @escaping @Sendable (URLRequest) -> StubServer.Response = { .file(FakeRepo.weights, for: $0) }
    ) -> StubServer {
        StubServer { request in
            let path = request.url?.path() ?? ""
            if path.hasPrefix("/api/models/") {
                return .json(info)
            }
            if path.hasSuffix("/resolve/\(revision)/config.json") {
                return .file(config, for: request)
            }
            if path.hasSuffix("/resolve/\(revision)/model.safetensors") {
                return weightsResponse(request)
            }
            return .init(status: 404, body: Data())
        }
    }
}

struct DownloaderTests {
    private func makeDownloader(_ server: StubServer, freeDisk: Int64? = 100 << 30) throws -> (ModelDownloader, ModelStorage) {
        let storage = ModelStorage(root: try temporaryDirectory().appending(path: "Models"))
        let downloader = ModelDownloader(
            storage: storage,
            hub: HubAPI(host: server.baseURL, session: server.session()),
            session: server.session(),
            freeDiskSpace: { freeDisk })
        return (downloader, storage)
    }

    @Test func downloadsModelFilesIntoStorage() async throws {
        let server = FakeRepo.server()
        let (downloader, storage) = try makeDownloader(server)
        let reports = Mutex<[DownloadProgress]>([])

        let folder = try await downloader.download(FakeRepo.entry) { progress in
            reports.withLock { $0.append(progress) }
        }

        #expect(folder == storage.directory(for: FakeRepo.repoID))
        #expect(storage.isInstalled(FakeRepo.repoID))
        #expect(try Data(contentsOf: folder.appending(path: "config.json")) == FakeRepo.config)
        #expect(try Data(contentsOf: folder.appending(path: "model.safetensors")) == FakeRepo.weights)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "README.md").path))
        #expect(!FileManager.default.fileExists(atPath: storage.partialDirectory(for: FakeRepo.repoID).path))
        let last = try #require(reports.withLock { $0.last })
        #expect(last.fraction == 1)
        #expect(last.totalBytes == Int64(FakeRepo.config.count + FakeRepo.weights.count))
        // Every request is pinned to the catalog's revision.
        let filePaths = server.requests.compactMap { $0.url?.path() }.filter { $0.contains("/resolve/") }
        #expect(!filePaths.isEmpty && filePaths.allSatisfy { $0.contains(FakeRepo.revision) })
    }

    @Test func resumesFromThePartialFileWithARangeRequest() async throws {
        let server = FakeRepo.server()
        let (downloader, storage) = try makeDownloader(server)
        let partial = storage.partialDirectory(for: FakeRepo.repoID)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FakeRepo.weights.prefix(7_000).write(to: partial.appending(path: "model.safetensors"))

        let folder = try await downloader.download(FakeRepo.entry) { _ in }

        let weightRequest = try #require(server.requests.first { $0.url?.path().hasSuffix("model.safetensors") == true })
        #expect(weightRequest.value(forHTTPHeaderField: "Range") == "bytes=7000-")
        #expect(try Data(contentsOf: folder.appending(path: "model.safetensors")) == FakeRepo.weights)
    }

    @Test func startsOverWhenTheServerIgnoresTheRange() async throws {
        let server = FakeRepo.server(weightsResponse: { _ in .init(status: 200, body: FakeRepo.weights) })
        let (downloader, storage) = try makeDownloader(server)
        let partial = storage.partialDirectory(for: FakeRepo.repoID)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FakeRepo.weights.prefix(7_000).write(to: partial.appending(path: "model.safetensors"))

        let folder = try await downloader.download(FakeRepo.entry) { _ in }

        #expect(try Data(contentsOf: folder.appending(path: "model.safetensors")) == FakeRepo.weights)
    }

    @Test func cancellingKeepsTheBytesForLaterAndResumes() async throws {
        let stalling = FakeRepo.server(weightsResponse: { request in
            var response = StubServer.Response.file(FakeRepo.weights, for: request)
            response.stallAfter = 5_000
            return response
        })
        let (downloader, storage) = try makeDownloader(stalling)
        let received = Mutex<Int64>(0)

        let task = Task {
            try await downloader.download(FakeRepo.entry) { progress in
                received.withLock { $0 = progress.completedBytes }
            }
        }
        let partialWeights = storage.partialDirectory(for: FakeRepo.repoID).appending(path: "model.safetensors")
        try await waitUntil { ModelStorage.fileSize(partialWeights) >= 5_000 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ModelStorage.fileSize(partialWeights) == 5_000)
        #expect(!storage.isInstalled(FakeRepo.repoID))

        // A new download of the same model asks only for the rest.
        let server = FakeRepo.server()
        let (resuming, _) = (
            ModelDownloader(
                storage: storage,
                hub: HubAPI(host: server.baseURL, session: server.session()),
                session: server.session(),
                freeDiskSpace: { 100 << 30 }),
            ()
        )
        let folder = try await resuming.download(FakeRepo.entry) { _ in }
        let weightRequest = try #require(server.requests.first { $0.url?.path().hasSuffix("model.safetensors") == true })
        #expect(weightRequest.value(forHTTPHeaderField: "Range") == "bytes=5000-")
        #expect(try Data(contentsOf: folder.appending(path: "model.safetensors")) == FakeRepo.weights)
    }

    @Test func refusesToStartWithoutEnoughFreeStorage() async throws {
        let server = FakeRepo.server()
        let (downloader, storage) = try makeDownloader(server, freeDisk: 1_000)

        await #expect {
            try await downloader.download(FakeRepo.entry) { _ in }
        } throws: { error in
            guard case DownloadError.notEnoughSpace(let needed, let available) = error else { return false }
            return available == 1_000 && needed > Int64(FakeRepo.weights.count)
        }
        #expect(!server.requests.contains { $0.url?.path().contains("/resolve/") == true })
        #expect(!storage.isInstalled(FakeRepo.repoID))
    }

    @Test func rejectsPathsOutsideTheModelFolder() async throws {
        let server = FakeRepo.server(info: FakeRepo.info(extraFile: "../escape.json"))
        let (downloader, _) = try makeDownloader(server)
        await #expect(throws: DownloadError.unsafePath("../escape.json")) {
            try await downloader.download(FakeRepo.entry) { _ in }
        }
    }

    @Test func detectsTruncatedFiles() async throws {
        let server = FakeRepo.server(info: FakeRepo.info(weightsSize: FakeRepo.weights.count + 10))
        let (downloader, storage) = try makeDownloader(server)
        await #expect(throws: DownloadError.sizeMismatch(file: "model.safetensors")) {
            try await downloader.download(FakeRepo.entry) { _ in }
        }
        #expect(!storage.isInstalled(FakeRepo.repoID))
    }

    @Test func reportsServerErrors() async throws {
        let server = FakeRepo.server(weightsResponse: { _ in .init(status: 403, body: Data()) })
        let (downloader, _) = try makeDownloader(server)
        await #expect(throws: DownloadError.badStatus(403)) {
            try await downloader.download(FakeRepo.entry) { _ in }
        }
    }
}

struct ModelStorageTests {
    @Test func prepareExcludesTheFolderFromBackup() throws {
        let storage = ModelStorage(root: try temporaryDirectory().appending(path: "Models"))
        try storage.prepare()
        let values = try storage.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func countsAndDeletesModels() throws {
        let storage = ModelStorage(root: try temporaryDirectory().appending(path: "Models"))
        try storage.prepare()
        #expect(storage.totalBytes() == 0)

        let installed = storage.directory(for: "a/one")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: installed.appending(path: "config.json"))
        let partial = storage.partialDirectory(for: "a/two")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(count: 30_000).write(to: partial.appending(path: "model.safetensors"))

        #expect(storage.isInstalled("a/one"))
        #expect(!storage.isInstalled("a/two"))
        #expect(storage.totalBytes() >= 80_000)

        try storage.delete("a/one")
        #expect(!storage.isInstalled("a/one"))
        try storage.deletePartial("a/two")
        #expect(storage.totalBytes() == 0)
        // Deleting what is not there is fine.
        try storage.delete("a/none")
    }
}

/// Polls `condition` every 10 ms for up to 5 s.
func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for a condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
