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
