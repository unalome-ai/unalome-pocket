import Foundation

/// One downloadable model, as listed in `catalog/catalog.json` (plan section 2).
public struct CatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Tier: String, Codable, Sendable, CaseIterable {
        case small, standard, large, macOnly
    }

    public struct License: Codable, Hashable, Sendable {
        public var name: String
        public var url: URL?

        public init(name: String, url: URL?) {
            self.name = name
            self.url = url
        }
    }

    /// Hugging Face repo ID, e.g. `mlx-community/Qwen3.5-0.8B-4bit`.
    public var id: String
    public var displayName: String
    /// Pinned commit SHA; downloads always fetch this exact revision.
    public var revision: String
    /// Bytes of the files the app downloads (weights, configs, tokenizer, chat template).
    public var downloadSizeBytes: Int64
    public var minimumMemoryBytes: Int64
    /// `true` until the value is measured on a real device.
    public var minimumMemoryIsEstimate: Bool
    public var supportsVision: Bool
    /// Memory needed to answer about an image: the vision model (loaded instead of the text
    /// model when a chat has an image) plus the image's processing. `nil` until measured; see
    /// `imageMemoryBytes`.
    public var visionMemoryBytes: Int64?
    public var license: License
    public var goodFor: String
    public var tier: Tier
    /// Editorial ordering by answer quality; higher is better.
    public var qualityRank: Int
    /// `false` for models added by ID, which nobody has checked.
    public var isVerified: Bool
    /// The chat template takes `enable_thinking`, so reasoning can be switched on and off.
    public var supportsThinking: Bool
    /// Delimiters around the reasoning in the model's output; `nil` means `<think>…</think>`.
    public var reasoningTags: ReasoningTags?

    /// Delimiters around a model's reasoning, as text.
    public struct ReasoningTags: Codable, Hashable, Sendable {
        public var start: String
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    public init(
        id: String,
        displayName: String,
        revision: String,
        downloadSizeBytes: Int64,
        minimumMemoryBytes: Int64,
        minimumMemoryIsEstimate: Bool,
        supportsVision: Bool,
        license: License,
        goodFor: String,
        tier: Tier,
        qualityRank: Int,
        isVerified: Bool = true,
        supportsThinking: Bool = false,
        reasoningTags: ReasoningTags? = nil,
        visionMemoryBytes: Int64? = nil
    ) {
        self.visionMemoryBytes = visionMemoryBytes
        self.id = id
        self.displayName = displayName
        self.revision = revision
        self.downloadSizeBytes = downloadSizeBytes
        self.minimumMemoryBytes = minimumMemoryBytes
        self.minimumMemoryIsEstimate = minimumMemoryIsEstimate
        self.supportsVision = supportsVision
        self.license = license
        self.goodFor = goodFor
        self.tier = tier
        self.qualityRank = qualityRank
        self.isVerified = isVerified
        self.supportsThinking = supportsThinking
        self.reasoningTags = reasoningTags
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, revision, downloadSizeBytes, minimumMemoryBytes, minimumMemoryIsEstimate
        case supportsVision, license, goodFor, tier, qualityRank, isVerified, supportsThinking, reasoningTags
        case visionMemoryBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        revision = try container.decode(String.self, forKey: .revision)
        downloadSizeBytes = try container.decode(Int64.self, forKey: .downloadSizeBytes)
        minimumMemoryBytes = try container.decode(Int64.self, forKey: .minimumMemoryBytes)
        minimumMemoryIsEstimate = try container.decode(Bool.self, forKey: .minimumMemoryIsEstimate)
        supportsVision = try container.decode(Bool.self, forKey: .supportsVision)
        license = try container.decode(License.self, forKey: .license)
        goodFor = try container.decode(String.self, forKey: .goodFor)
        tier = try container.decode(Tier.self, forKey: .tier)
        qualityRank = try container.decode(Int.self, forKey: .qualityRank)
        // Everything in the curated catalog is verified.
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified) ?? true
        supportsThinking = try container.decodeIfPresent(Bool.self, forKey: .supportsThinking) ?? false
        reasoningTags = try container.decodeIfPresent(ReasoningTags.self, forKey: .reasoningTags)
        visionMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .visionMemoryBytes)
    }

    /// Memory needed to answer about an image. Unmeasured vision models are assumed to need a
    /// quarter more than for text: the vision tower and the image's processing.
    public var imageMemoryBytes: Int64 {
        visionMemoryBytes ?? minimumMemoryBytes + minimumMemoryBytes / 4
    }
}

public struct Catalog: Codable, Hashable, Sendable {
    /// Format version; a file with a newer version is ignored.
    public var version: Int
    public var models: [CatalogEntry]

    public static let supportedVersion = 1

    public init(version: Int = Catalog.supportedVersion, models: [CatalogEntry]) {
        self.version = version
        self.models = models
    }

    public func entry(id: String) -> CatalogEntry? {
        models.first { $0.id == id }
    }
}

/// Rough memory needed to run a 4-bit model: the weights, plus 20% for runtime buffers,
/// plus 512 MiB for the KV cache and activations of a chat-length context.
/// Used for the catalog values (all marked as estimates) and for models added by ID.
public enum MemoryEstimate {
    public static func bytes(forWeights weightBytes: Int64) -> Int64 {
        weightBytes + weightBytes / 5 + 512 * 1024 * 1024
    }
}
