import Foundation

/// Whether Apple's built-in model can be used. Mirrors `SystemLanguageModel.Availability`
/// without importing FoundationModels here.
public enum AppleModelAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    public var isAvailable: Bool { self == .available }

    public var explanation: String {
        switch self {
        case .available: "Ready on this device."
        case .deviceNotEligible: "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in Settings to use it."
        case .modelNotReady: "Apple's model is still downloading. Try again later."
        }
    }
}

public enum ModelLabel: Sendable, Equatable {
    /// The one model to pick on this device.
    case recommended
    /// Fits with room to spare.
    case runsWell
    /// Fits, but close to the limit, or measured as slow.
    case tight
    case tooLarge(reason: String)

    public var isUsable: Bool {
        if case .tooLarge = self { false } else { true }
    }
}

/// How well a model can answer about images on a device.
public enum ImageUse: Sendable, Equatable {
    /// Text only, or not checked (models added by ID).
    case unsupported
    case fits
    /// Fits, but close to the memory limit.
    case tight
    /// The vision model does not fit; the model is text-only on this device.
    case tooLarge
}

public struct Recommendation: Sendable, Equatable {
    public var labels: [String: ModelLabel]
    /// `nil` when no catalog model fits this device.
    public var recommendedID: String?
    public var appleModel: AppleModelAvailability

    public func label(for id: String) -> ModelLabel {
        labels[id] ?? .tooLarge(reason: "Unknown model.")
    }
}

/// What a model was measured to need on this device, from finished replies.
public struct ModelMeasurement: Sendable, Equatable {
    public var tokensPerSecond: Double?
    /// Peak memory the model used (inference runtime peak, weights included).
    public var peakMemoryBytes: Int64?

    public init(tokensPerSecond: Double? = nil, peakMemoryBytes: Int64? = nil) {
        self.tokensPerSecond = tokensPerSecond
        self.peakMemoryBytes = peakMemoryBytes
    }

    /// A reply ran to the end with this model, so it demonstrably fits.
    public var hasRun: Bool { tokensPerSecond != nil || peakMemoryBytes != nil }
}

/// Decides, per catalog model, how well it suits a device. Pure: same inputs, same answer.
///
/// `device.memoryBudgetBytes` must be the budget measured at launch, before any model loaded
/// (see `DeviceProfileProvider`); otherwise a loaded model would shrink every other model's room.
public enum ModelRecommender {
    /// A model fits "with room" when it needs at most this share of the memory budget.
    public static let memoryMargin = 0.85
    /// Free storage that must remain after a download.
    public static let diskHeadroomBytes: Int64 = 1 << 30
    /// Below this measured speed a model is treated as too slow to recommend.
    public static let slowTokensPerSecond = 8.0

    public static func recommend(
        catalog: [CatalogEntry],
        device: DeviceProfile,
        measurements: [String: ModelMeasurement] = [:],
        installedIDs: Set<String> = [],
        appleModel: AppleModelAvailability
    ) -> Recommendation {
        var labels: [String: ModelLabel] = [:]
        for entry in catalog {
            labels[entry.id] = fitLabel(
                entry, device: device, measurement: measurements[entry.id],
                isInstalled: installedIDs.contains(entry.id))
        }
        let isSlow = { (entry: CatalogEntry) in
            (measurements[entry.id]?.tokensPerSecond ?? .infinity) < slowTokensPerSecond
        }
        for entry in catalog where isSlow(entry) && labels[entry.id] == .runsWell {
            labels[entry.id] = .tight
        }

        // Best quality first. Prefer a model with room to spare, then a tight one that is not
        // measured as slow, then the one needing the least memory.
        let byQuality = catalog.sorted { $0.qualityRank > $1.qualityRank }
        let pick = byQuality.first { labels[$0.id] == .runsWell }
            ?? byQuality.first { labels[$0.id] == .tight && !isSlow($0) }
            ?? catalog.filter { labels[$0.id] == .tight }.min {
                requiredMemory($0, measurements[$0.id]) < requiredMemory($1, measurements[$1.id])
            }

        if let pick {
            labels[pick.id] = .recommended
        }
        return Recommendation(labels: labels, recommendedID: pick?.id, appleModel: appleModel)
    }

    /// Whether a model can answer about images on this device. Same rule as for text, against
    /// the vision model's estimate: images load a larger model than text does.
    public static func imageUse(_ entry: CatalogEntry, device: DeviceProfile) -> ImageUse {
        guard entry.supportsVision, entry.isVerified else { return .unsupported }
        let needed = entry.imageMemoryBytes
        let budget = device.memoryBudgetBytes
        if needed > budget { return .tooLarge }
        return Double(needed) > Double(budget) * memoryMargin ? .tight : .fits
    }

    /// Vision models that can read images on this device, best first, for suggesting instead of
    /// one that cannot.
    public static func imageCapableAlternatives(
        to entry: CatalogEntry, in catalog: [CatalogEntry], device: DeviceProfile, limit: Int = 2
    ) -> [CatalogEntry] {
        catalog
            .filter { $0.id != entry.id && imageUse($0, device: device) == .fits }
            .sorted { $0.qualityRank > $1.qualityRank }
            .prefix(limit)
            .map { $0 }
    }

    /// The error a chat shows when an image is sent to a model this device cannot run it with.
    public static func imageTooLargeMessage(alternatives: [CatalogEntry]) -> String {
        let base = "This model needs more memory than this device has free to read images."
        let names = alternatives.map(\.displayName)
        switch names.count {
        case 0: return base + " Ask without the photo, or use a Mac."
        case 1: return base + " Try \(names[0])."
        default: return base + " Try \(names.dropLast().joined(separator: ", ")) or \(names.last!)."
        }
    }

    /// Memory a model needs: measured on this device when known, otherwise the estimate.
    public static func requiredMemory(_ entry: CatalogEntry, _ measurement: ModelMeasurement?) -> Int64 {
        measurement?.peakMemoryBytes ?? entry.minimumMemoryBytes
    }

    private static func fitLabel(
        _ entry: CatalogEntry, device: DeviceProfile, measurement: ModelMeasurement?, isInstalled: Bool
    ) -> ModelLabel {
        let hasRun = isInstalled && measurement?.hasRun == true
        if entry.tier == .macOnly, device.kind != .mac, !hasRun {
            return .tooLarge(reason: "Made for Macs with 16 GB or more.")
        }
        let budget = device.memoryBudgetBytes
        let needed = requiredMemory(entry, measurement)
        if needed > budget {
            // It ran here before, so the estimate or budget is off; never call it too large.
            if hasRun { return .tight }
            return .tooLarge(
                reason: "Needs about \(ByteFormat.memory(needed)) of memory; "
                    + "this device can spare about \(ByteFormat.memory(budget)).")
        }
        if !isInstalled, let free = device.freeDiskBytes, entry.downloadSizeBytes + diskHeadroomBytes > free {
            return .tooLarge(
                reason: "Needs \(ByteFormat.file(entry.downloadSizeBytes + diskHeadroomBytes)) of free storage.")
        }
        if Double(needed) > Double(budget) * memoryMargin {
            return .tight
        }
        return .runsWell
    }
}

/// Human-readable sizes, e.g. "1.4 GB".
public enum ByteFormat {
    public static func file(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
