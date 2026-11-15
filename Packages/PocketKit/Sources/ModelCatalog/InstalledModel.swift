import Foundation
import SwiftData

/// A model whose files are on this device.
@Model
public final class InstalledModel {
    @Attribute(.unique) public var repoID: String
    public var displayName: String
    public var revision: String
    public var sizeBytes: Int64
    public var minimumMemoryBytes: Int64
    /// `false` for models added by ID.
    public var isVerified: Bool
    public var supportsVision: Bool
    public var licenseName: String
    public var licenseURL: URL?
    public var licenseAcceptedAt: Date
    public var installedAt: Date
    /// Decode speed measured during chats on this device, if any.
    public var measuredTokensPerSecond: Double?
    /// Highest inference-runtime peak seen during chats on this device (weights included).
    public var measuredPeakMemoryBytes: Int64?
    /// The app's whole memory footprint at the end of the reply with that peak.
    public var measuredFootprintBytes: Int64?

    public var measurement: ModelMeasurement {
        ModelMeasurement(tokensPerSecond: measuredTokensPerSecond, peakMemoryBytes: measuredPeakMemoryBytes)
    }

    public init(entry: CatalogEntry, licenseAcceptedAt: Date, installedAt: Date = .now) {
        repoID = entry.id
        displayName = entry.displayName
        revision = entry.revision
        sizeBytes = entry.downloadSizeBytes
        minimumMemoryBytes = entry.minimumMemoryBytes
        isVerified = entry.isVerified
        supportsVision = entry.supportsVision
        licenseName = entry.license.name
        licenseURL = entry.license.url
        self.licenseAcceptedAt = licenseAcceptedAt
        self.installedAt = installedAt
    }
}
