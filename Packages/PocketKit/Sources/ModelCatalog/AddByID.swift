import Foundation

/// Checks a model the user typed in by ID and turns it into an unverified catalog entry.
public enum AddByID {
    public enum Problem: LocalizedError, Equatable {
        case notMLX
        case missingConfig
        case missingWeights
        case gated

        public var errorDescription: String? {
            switch self {
            case .notMLX: "This model has no MLX weights. Look for a converted version, e.g. from mlx-community."
            case .missingConfig: "This model has no config.json, so it cannot be loaded."
            case .missingWeights: "This model has no .safetensors weights."
            case .gated: HubAPI.HubError.gated.errorDescription
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public var entry: CatalogEntry
        /// Set when the model probably does not fit this device.
        public var warning: String?
    }

    /// Builds an unverified entry pinned to the revision the metadata describes.
    public static func evaluate(repoID: String, info: HubModelInfo, device: DeviceProfile) throws -> Result {
        guard !info.isGated else { throw Problem.gated }
        guard info.isMLX else { throw Problem.notMLX }
        guard info.files.contains(where: { $0.path == "config.json" }) else { throw Problem.missingConfig }
        guard info.files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw Problem.missingWeights }

        let size = info.modelFilesSize
        let memory = MemoryEstimate.bytes(forWeights: size)
        let entry = CatalogEntry(
            id: repoID,
            displayName: repoID.split(separator: "/").last.map(String.init) ?? repoID,
            revision: info.sha,
            downloadSizeBytes: size,
            minimumMemoryBytes: memory,
            minimumMemoryIsEstimate: true,
            supportsVision: false,
            license: CatalogEntry.License(
                name: info.licenseName ?? "Unknown licence",
                url: URL(string: "https://huggingface.co/\(repoID)")
            ),
            goodFor: "Added by you. Not checked by Unalome.",
            tier: .standard,
            qualityRank: 0,
            isVerified: false
        )

        var warning: String?
        if memory > device.memoryBudgetBytes {
            warning = "Needs about \(ByteFormat.memory(memory)) of memory, more than this device can spare "
                + "(about \(ByteFormat.memory(device.memoryBudgetBytes))). It may not load."
        } else if let free = device.freeDiskBytes, size + ModelRecommender.diskHeadroomBytes > free {
            warning = "Needs \(ByteFormat.file(size)) and there is not enough free storage."
        }
        return Result(entry: entry, warning: warning)
    }
}
