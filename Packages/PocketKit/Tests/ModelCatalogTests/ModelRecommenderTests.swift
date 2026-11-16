import Foundation
import Testing
@testable import ModelCatalog

private let gib: Int64 = 1 << 30
private let plentyOfDisk: Int64 = 200 * gib

private enum ID {
    static let qwen08 = "mlx-community/Qwen3.5-0.8B-4bit"
    static let gemma1 = "mlx-community/gemma-3-1b-it-qat-4bit"
    static let lfm = "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    static let qwen2 = "mlx-community/Qwen3.5-2B-4bit"
    static let gemmaE2 = "mlx-community/gemma-4-e2b-it-4bit"
    static let qwen4 = "mlx-community/Qwen3.5-4B-MLX-4bit"
    static let gemmaE4 = "mlx-community/gemma-4-e4b-it-4bit"
    static let qwen9 = "mlx-community/Qwen3.5-9B-MLX-4bit"
}

/// One row of the table: a device, the model it should recommend, and labels to check.
struct RecommenderCase: CustomTestStringConvertible, Sendable {
    var name: String
    var device: DeviceProfile
    var recommended: String?
    var runsWell: [String] = []
    var tight: [String] = []
    var tooLarge: [String] = []

    var testDescription: String { name }
}

/// Devices without an OS-reported memory headroom get 60% of RAM as the budget.
private func phone(_ ramGiB: Int64, freeDisk: Int64 = plentyOfDisk) -> DeviceProfile {
    DeviceProfile(kind: .phone, physicalMemoryBytes: ramGiB * gib, freeDiskBytes: freeDisk)
}

private let table: [RecommenderCase] = [
    RecommenderCase(
        name: "4 GB phone",
        device: phone(4),
        recommended: ID.lfm,
        runsWell: [ID.qwen08, ID.gemma1],
        tooLarge: [ID.qwen2, ID.gemmaE2, ID.qwen4, ID.gemmaE4, ID.qwen9]),
    RecommenderCase(
        name: "6 GB phone",
        device: phone(6),
        recommended: ID.qwen2,
        runsWell: [ID.qwen08, ID.gemma1, ID.lfm],
        tooLarge: [ID.gemmaE2, ID.qwen4, ID.gemmaE4, ID.qwen9]),
    RecommenderCase(
        name: "8 GB phone (iPhone 15 Pro)",
        device: phone(8),
        recommended: ID.qwen4,
        runsWell: [ID.qwen08, ID.gemma1, ID.lfm, ID.qwen2],
        tight: [ID.gemmaE2],
        tooLarge: [ID.gemmaE4, ID.qwen9]),
    RecommenderCase(
        name: "12 GB phone",
        device: phone(12),
        recommended: ID.qwen4,
        runsWell: [ID.qwen2, ID.gemmaE2],
        tight: [ID.gemmaE4],
        tooLarge: [ID.qwen9]),
    RecommenderCase(
        name: "16 GB Mac",
        device: DeviceProfile(kind: .mac, physicalMemoryBytes: 16 * gib, freeDiskBytes: plentyOfDisk),
        recommended: ID.qwen9,
        runsWell: [ID.gemmaE4, ID.qwen4]),
    RecommenderCase(
        name: "16 GB iPad does not get the Mac-only model",
        device: DeviceProfile(kind: .pad, physicalMemoryBytes: 16 * gib, freeDiskBytes: plentyOfDisk),
        recommended: ID.gemmaE4,
        tooLarge: [ID.qwen9]),
    RecommenderCase(
        name: "8 GB phone with 2.5 GB free storage",
        device: phone(8, freeDisk: 2_500_000_000),
        recommended: ID.lfm,
        runsWell: [ID.qwen08, ID.gemma1],
        tooLarge: [ID.qwen2, ID.gemmaE2, ID.qwen4, ID.gemmaE4]),
    RecommenderCase(
        name: "OS-reported headroom wins over RAM",
        device: DeviceProfile(
            kind: .phone, physicalMemoryBytes: 8 * gib, availableMemoryBytes: 3 * gib, freeDiskBytes: plentyOfDisk),
        recommended: ID.qwen2,
        tooLarge: [ID.qwen4]),
    RecommenderCase(
        name: "Only tight fits: the best one is recommended",
        device: DeviceProfile(
            kind: .phone, physicalMemoryBytes: 4 * gib, availableMemoryBytes: 1_400_000_000,
            freeDiskBytes: plentyOfDisk),
        recommended: ID.lfm,
        tight: [ID.qwen08],
        tooLarge: [ID.gemma1, ID.qwen2]),
    RecommenderCase(
        name: "Nothing fits",
        device: phone(2),
        recommended: nil,
        tooLarge: [ID.qwen08, ID.gemma1, ID.lfm, ID.qwen2]),
]

struct ModelRecommenderTests {
    private let catalog: [CatalogEntry]

    init() throws {
        catalog = try CatalogLoader.bundled().models
    }

    @Test(arguments: table)
    func recommendsPerDevice(_ row: RecommenderCase) {
        let result = ModelRecommender.recommend(catalog: catalog, device: row.device, appleModel: .available)

        #expect(result.recommendedID == row.recommended)
        let recommendedLabels = catalog.filter { result.label(for: $0.id) == .recommended }
        #expect(recommendedLabels.count == (row.recommended == nil ? 0 : 1), "exactly one recommended model")
        for id in row.runsWell {
            #expect(result.label(for: id) == .runsWell, "\(id)")
        }
        for id in row.tight {
            #expect(result.label(for: id) == .tight, "\(id)")
        }
        for id in row.tooLarge {
            #expect(!result.label(for: id).isUsable, "\(id)")
        }
    }

    @Test func everyCatalogModelGetsALabel() {
        let result = ModelRecommender.recommend(catalog: catalog, device: phone(8), appleModel: .deviceNotEligible)
        #expect(Set(result.labels.keys) == Set(catalog.map(\.id)))
        #expect(result.appleModel == .deviceNotEligible)
    }

    @Test func measuredSlowSpeedDemotesTheRecommendation() {
        let result = ModelRecommender.recommend(
            catalog: catalog, device: phone(8), measurements: [ID.qwen4: ModelMeasurement(tokensPerSecond: 5)], appleModel: .available)
        #expect(result.label(for: ID.qwen4) == .tight)
        #expect(result.recommendedID == ID.qwen2)
    }

    @Test func fastMeasuredSpeedKeepsTheRecommendation() {
        let result = ModelRecommender.recommend(
            catalog: catalog, device: phone(8), measurements: [ID.qwen4: ModelMeasurement(tokensPerSecond: 20)], appleModel: .available)
        #expect(result.recommendedID == ID.qwen4)
    }

    @Test func installedModelsIgnoreTheDiskCheck() {
        let lowDisk = phone(8, freeDisk: 2_500_000_000)
        let result = ModelRecommender.recommend(
            catalog: catalog, device: lowDisk, installedIDs: [ID.qwen4], appleModel: .available)
        #expect(result.recommendedID == ID.qwen4)
        #expect(!result.label(for: ID.qwen2).isUsable)
    }

    @Test func tooLargeExplainsWhy() throws {
        let result = ModelRecommender.recommend(catalog: catalog, device: phone(4), appleModel: .available)
        guard case .tooLarge(let reason) = result.label(for: ID.qwen4) else {
            Issue.record("expected tooLarge")
            return
        }
        #expect(reason.contains("memory"))
    }

    /// The phone report: with Qwen 3.5 4B loaded, `os_proc_available_memory` fell to about
    /// 3.5 GB and Gemma 4 E2B became "too large". The budget must be the launch reading.
    @Test func aLoadedModelDoesNotShrinkOtherModelsRoom() {
        let available = AvailableMemory(6_800_000_000)
        let provider = DeviceProfileProvider {
            DeviceProfile(
                kind: .phone, physicalMemoryBytes: 8 * gib, availableMemoryBytes: available.value,
                freeDiskBytes: plentyOfDisk, machineIdentifier: "iPhone16,1")
        }
        let atLaunch = ModelRecommender.recommend(catalog: catalog, device: provider.current(), appleModel: .available)

        available.value = 3_500_000_000  // Qwen 3.5 4B is now loaded
        let whileLoaded = ModelRecommender.recommend(
            catalog: catalog, device: provider.current(), installedIDs: [ID.qwen4], appleModel: .available)

        #expect(provider.current().memoryBudgetBytes == 6_800_000_000)
        #expect(whileLoaded.label(for: ID.gemmaE2).isUsable)
        #expect(atLaunch.labels.filter { $0.key != ID.qwen4 } == whileLoaded.labels.filter { $0.key != ID.qwen4 })
    }

    @Test func measuredPeakOverridesTheEstimate() {
        // Estimated 4.5 GB: tight on a 5 GB budget. Measured at 3 GB: room to spare.
        let device = DeviceProfile(
            kind: .phone, physicalMemoryBytes: 8 * gib, availableMemoryBytes: 5_000_000_000,
            freeDiskBytes: plentyOfDisk)
        let estimated = ModelRecommender.recommend(catalog: catalog, device: device, appleModel: .available)
        #expect(estimated.label(for: ID.gemmaE2) == .tight)

        let measured = ModelRecommender.recommend(
            catalog: catalog, device: device,
            measurements: [ID.gemmaE2: ModelMeasurement(tokensPerSecond: 20, peakMemoryBytes: 3_000_000_000)],
            installedIDs: [ID.gemmaE2], appleModel: .available)
        #expect(measured.label(for: ID.gemmaE2) != .tight)
        #expect(measured.label(for: ID.gemmaE2).isUsable)
    }

    @Test func aModelThatRanIsNeverTooLarge() {
        let device = DeviceProfile(
            kind: .phone, physicalMemoryBytes: 8 * gib, availableMemoryBytes: 3_000_000_000,
            freeDiskBytes: plentyOfDisk)
        let result = ModelRecommender.recommend(
            catalog: catalog, device: device,
            measurements: [ID.qwen4: ModelMeasurement(tokensPerSecond: 16)],
            installedIDs: [ID.qwen4], appleModel: .available)
        #expect(result.label(for: ID.qwen4).isUsable)
        // Not installed, or installed but never run: the estimate decides.
        let unproven = ModelRecommender.recommend(
            catalog: catalog, device: device, installedIDs: [ID.qwen4], appleModel: .available)
        #expect(!unproven.label(for: ID.qwen4).isUsable)
    }

    @Test func sameInputSameAnswer() {
        let first = ModelRecommender.recommend(catalog: catalog, device: phone(8), appleModel: .available)
        let second = ModelRecommender.recommend(
            catalog: catalog.reversed(), device: phone(8), appleModel: .available)
        #expect(first == second)
    }
}

/// Memory the fake OS reports, changed by the test.
private final class AvailableMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64

    init(_ bytes: Int64) { self.bytes = bytes }

    var value: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

/// Images load a larger model than text, so whether a model can read them is judged separately.
struct ImageUseTests {
    private let catalog = try! CatalogLoader.bundled().models
    private func entry(_ id: String) -> CatalogEntry { catalog.first { $0.id == id }! }
    /// iPhone 15 Pro-like: 8 GB, with the budget the OS reports at launch.
    private func phone(budgetGiB: Double) -> DeviceProfile {
        DeviceProfile(kind: .phone, physicalMemoryBytes: 8 * gib, availableMemoryBytes: Int64(budgetGiB * Double(gib)))
    }

    @Test func measuredVisionModelsCarryTheirImageMemory() {
        for id in [ID.qwen08, ID.qwen2, ID.qwen4, ID.gemmaE2] {
            let model = entry(id)
            let vision = try! #require(model.visionMemoryBytes, "\(id)")
            #expect(vision > model.minimumMemoryBytes, "\(id): images need more than text")
            #expect(model.imageMemoryBytes == vision)
        }
        // Unmeasured: a quarter more than for text.
        let e4 = entry(ID.gemmaE4)
        #expect(e4.visionMemoryBytes == nil)
        #expect(e4.imageMemoryBytes == e4.minimumMemoryBytes + e4.minimumMemoryBytes / 4)
    }

    @Test func imageUseFollowsTheVisionEstimate() {
        let device = phone(budgetGiB: 5.4)
        #expect(ModelRecommender.imageUse(entry(ID.gemma1), device: device) == .unsupported)
        #expect(ModelRecommender.imageUse(entry(ID.qwen08), device: device) == .fits)
        #expect(ModelRecommender.imageUse(entry(ID.qwen2), device: device) == .fits)
        // Text fits (4.2 GB), images do not (5.9 GB needed): text-only on this device.
        let labels = ModelRecommender.recommend(catalog: catalog, device: device, appleModel: .deviceNotEligible)
        #expect(labels.label(for: ID.qwen4).isUsable)
        #expect(ModelRecommender.imageUse(entry(ID.qwen4), device: device) == .tooLarge)
        #expect(ModelRecommender.imageUse(entry(ID.gemmaE2), device: device) == .tight)
        // More room: the 4B reads images, close to the limit.
        #expect(ModelRecommender.imageUse(entry(ID.qwen4), device: phone(budgetGiB: 6)) == .tight)
    }

    @Test func modelsAddedByIDAreNotPromisedImages() {
        var added = entry(ID.qwen2)
        added.isVerified = false
        #expect(ModelRecommender.imageUse(added, device: phone(budgetGiB: 7)) == .unsupported)
    }

    @Test func suggestsModelsThatFit() {
        let alternatives = ModelRecommender.imageCapableAlternatives(
            to: entry(ID.qwen4), in: catalog, device: phone(budgetGiB: 5.4))
        #expect(alternatives.map(\.id) == [ID.qwen2, ID.qwen08])
        #expect(ModelRecommender.imageTooLargeMessage(alternatives: alternatives)
            == "This model needs more memory than this device has free to read images. Try Qwen 3.5 2B or Qwen 3.5 0.8B.")
        #expect(ModelRecommender.imageTooLargeMessage(alternatives: Array(alternatives.prefix(1)))
            == "This model needs more memory than this device has free to read images. Try Qwen 3.5 2B.")
        #expect(ModelRecommender.imageTooLargeMessage(alternatives: []).hasSuffix("Ask without the photo, or use a Mac."))
    }

    @Test func imageSizeIsSmallerOnDevicesWithLessMemory() {
        // An 8 GB iPhone reports a little under 8 GiB.
        let iPhone = DeviceProfile(kind: .phone, physicalMemoryBytes: 7_900_000_000)
        let mac = DeviceProfile(kind: .mac, physicalMemoryBytes: 16 * gib)
        #expect(ImageSizePolicy.maxDimension(for: iPhone) == 1024)
        #expect(ImageSizePolicy.maxDimension(for: mac) == 1536)
    }
}

struct ModelCapabilityTests {
    private let catalog = try! CatalogLoader.bundled().models
    private func entry(_ id: String) -> CatalogEntry { catalog.first { $0.id == id }! }

    @Test func visionModel() {
        // Qwen 3.5 2B: images and thinking.
        let capabilities = ModelCapabilities(entry(ID.qwen2))
        #expect(capabilities.capabilities == [.text, .image, .voice, .thinking])
        #expect(capabilities.accessibilityText == "Supports text, image, voice, thinking")
    }

    @Test func textOnlyModel() {
        let capabilities = ModelCapabilities(entry(ID.lfm))
        #expect(capabilities.capabilities == [.text, .voice])
        #expect(capabilities.accessibilityText == "Supports text, voice")
    }

    @Test func thinkingWithoutVision() {
        var thinker = entry(ID.lfm)
        thinker.supportsThinking = true
        #expect(ModelCapabilities(thinker).capabilities == [.text, .voice, .thinking])
    }

    @Test func appleBuiltIn() {
        #expect(ModelCapabilities.appleOnDevice.capabilities == [.text, .voice])
    }

    @Test func unverifiedAddByIDRepoShowsTextAndVoiceOnly() {
        var added = entry(ID.qwen2)
        added.isVerified = false
        #expect(ModelCapabilities(added).capabilities == [.text, .voice])
    }

    @Test func imageDependsOnTheDevice() {
        let phone = DeviceProfile(kind: .phone, physicalMemoryBytes: 8 * gib, availableMemoryBytes: Int64(5.4 * Double(gib)))
        // The 4B reads images only where its vision model fits.
        #expect(ModelCapabilities(entry(ID.qwen4), device: phone).capabilities == [.text, .voice, .thinking])
        let gemma = ModelCapabilities(entry(ID.gemmaE2), device: phone)
        #expect(gemma.capabilities.contains(.image) && gemma.imageIsTight)
        #expect(gemma.accessibilityText.hasSuffix("close to this device's memory limit"))
        let mac = DeviceProfile(kind: .mac, physicalMemoryBytes: 32 * gib)
        #expect(ModelCapabilities(entry(ID.qwen4), device: mac).capabilities == [.text, .image, .voice, .thinking])
    }

    @Test func accentedCapabilities() {
        #expect(ModelCapability.allCases.filter(\.isAccented) == [.image, .thinking])
    }
}
