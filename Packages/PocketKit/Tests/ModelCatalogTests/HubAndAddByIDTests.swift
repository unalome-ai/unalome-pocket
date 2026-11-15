import Foundation
import Testing
@testable import ModelCatalog

struct HubAndAddByIDTests {
    private static let mlxInfo = """
        {
          "sha": "0123456789abcdef0123456789abcdef01234567",
          "library_name": "mlx",
          "tags": ["mlx", "text-generation"],
          "gated": false,
          "cardData": {"license": "apache-2.0"},
          "siblings": [
            {"rfilename": "config.json", "size": 1000},
            {"rfilename": "model.safetensors", "size": 1000000000},
            {"rfilename": "tokenizer.json", "size": 5000},
            {"rfilename": "chat_template.jinja", "size": 200},
            {"rfilename": "README.md", "size": 300},
            {"rfilename": "images/example.png", "size": 9000}
          ]
        }
        """

    private static func info(_ json: String = mlxInfo) throws -> HubModelInfo {
        try JSONDecoder().decode(HubModelInfo.self, from: Data(json.utf8))
    }

    private static let roomyPhone = DeviceProfile(
        kind: .phone, physicalMemoryBytes: 8 << 30, freeDiskBytes: 100 << 30)

    @Test(arguments: [
        ("mlx-community/Qwen3.5-0.8B-4bit", true),
        ("org/model_name.v2", true),
        ("model-only", false),
        ("a/b/c", false),
        ("org/", false),
        ("../etc", false),
        ("org/..", false),
        ("org/.hidden", false),
        ("org/name with space", false),
        ("org/naïve", false),
    ])
    func validatesRepoIDs(_ id: String, _ valid: Bool) {
        #expect(RepoID.isValid(id) == valid)
    }

    @Test func decodesModelInfo() throws {
        let info = try Self.info()
        #expect(info.isMLX)
        #expect(!info.isGated)
        #expect(info.licenseName == "apache-2.0")
        #expect(info.modelFiles.map(\.path) == ["config.json", "model.safetensors", "tokenizer.json", "chat_template.jinja"])
        #expect(info.modelFilesSize == 1_000_006_200)
    }

    @Test func readsGatedFlagAndCustomLicenceName() throws {
        let info = try Self.info(
            #"{"sha": "x", "gated": "manual", "cardData": {"license": "other", "license_name": "lfm1.0"}}"#)
        #expect(info.isGated)
        #expect(info.licenseName == "lfm1.0")
        #expect(info.files.isEmpty)
    }

    @Test func addByIDBuildsAnUnverifiedPinnedEntry() throws {
        let result = try AddByID.evaluate(repoID: "someone/Tiny-4bit", info: Self.info(), device: Self.roomyPhone)
        #expect(!result.entry.isVerified)
        #expect(result.entry.revision == "0123456789abcdef0123456789abcdef01234567")
        #expect(result.entry.displayName == "Tiny-4bit")
        #expect(result.entry.downloadSizeBytes == 1_000_006_200)
        #expect(result.entry.minimumMemoryBytes == MemoryEstimate.bytes(forWeights: 1_000_006_200))
        #expect(result.entry.minimumMemoryIsEstimate)
        #expect(result.entry.license.name == "apache-2.0")
        #expect(result.warning == nil)
    }

    @Test func addByIDWarnsWhenOverBudget() throws {
        let small = DeviceProfile(kind: .phone, physicalMemoryBytes: 2 << 30, freeDiskBytes: 100 << 30)
        let result = try AddByID.evaluate(repoID: "someone/Tiny-4bit", info: Self.info(), device: small)
        #expect(result.warning?.contains("memory") == true)
    }

    @Test func addByIDWarnsWhenStorageIsShort() throws {
        let full = DeviceProfile(kind: .phone, physicalMemoryBytes: 8 << 30, freeDiskBytes: 500_000_000)
        let result = try AddByID.evaluate(repoID: "someone/Tiny-4bit", info: Self.info(), device: full)
        #expect(result.warning?.contains("storage") == true)
    }

    @Test func addByIDRejectsUnusableRepos() throws {
        let notMLX = #"{"sha": "x", "library_name": "transformers", "siblings": [{"rfilename": "config.json"}]}"#
        #expect(throws: AddByID.Problem.notMLX) {
            try AddByID.evaluate(repoID: "a/b", info: Self.info(notMLX), device: Self.roomyPhone)
        }
        let noWeights = #"{"sha": "x", "tags": ["mlx"], "siblings": [{"rfilename": "config.json"}]}"#
        #expect(throws: AddByID.Problem.missingWeights) {
            try AddByID.evaluate(repoID: "a/b", info: Self.info(noWeights), device: Self.roomyPhone)
        }
        let noConfig = #"{"sha": "x", "tags": ["mlx"], "siblings": [{"rfilename": "model.safetensors"}]}"#
        #expect(throws: AddByID.Problem.missingConfig) {
            try AddByID.evaluate(repoID: "a/b", info: Self.info(noConfig), device: Self.roomyPhone)
        }
        let gated = #"{"sha": "x", "tags": ["mlx"], "gated": "auto"}"#
        #expect(throws: AddByID.Problem.gated) {
            try AddByID.evaluate(repoID: "a/b", info: Self.info(gated), device: Self.roomyPhone)
        }
    }

    @Test func hubRequestsPinnedRevisionWithoutPersonalData() async throws {
        let server = StubServer { _ in .json(Self.mlxInfo) }
        let hub = HubAPI(host: server.baseURL, session: server.session())

        let info = try await hub.modelInfo(repoID: "someone/Tiny-4bit", revision: "abc")

        #expect(info.isMLX)
        let request = try #require(server.requests.first)
        #expect(request.url?.path() == "/api/models/someone/Tiny-4bit/revision/abc")
        #expect(request.url?.query() == "blobs=true")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UnalomePocket")
    }

    @Test func hubMapsMissingReposToNotFound() async throws {
        let server = StubServer { _ in .init(status: 404, body: Data()) }
        let hub = HubAPI(host: server.baseURL, session: server.session())
        await #expect(throws: HubAPI.HubError.notFound) { try await hub.modelInfo(repoID: "no/such") }
        await #expect(throws: HubAPI.HubError.invalidRepoID) { try await hub.modelInfo(repoID: "no-slash") }
        #expect(server.requests.count == 1)
    }

    @Test func fileURLPointsAtThePinnedRevision() {
        let url = HubAPI().fileURL(repoID: "org/model", revision: "abc123", path: "sub/model.safetensors")
        #expect(url.absoluteString == "https://huggingface.co/org/model/resolve/abc123/sub/model.safetensors")
    }
}
