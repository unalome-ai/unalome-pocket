import Foundation
import Observation
import SwiftData

/// The models screen's state: the catalog, installed models, downloads and storage.
@MainActor
@Observable
public final class ModelLibrary {
    public enum DownloadState: Equatable, Sendable {
        case downloading(DownloadProgress?)
        /// Stopped by the user or interrupted; the bytes so far are kept.
        case paused(DownloadProgress?)
        case failed(String)
    }

    /// What happened to a download, for observers such as the Live Activity.
    public enum DownloadEvent: Sendable {
        case started(CatalogEntry)
        case changed(repoID: String, DownloadState)
        case finished(CatalogEntry)
        /// Discarded by the user: the bytes are gone.
        case removed(repoID: String)
    }

    @ObservationIgnored private var downloadObservers: [@MainActor (DownloadEvent) -> Void] = []

    /// Calls `handler` for every download event from now on.
    public func observeDownloads(_ handler: @escaping @MainActor (DownloadEvent) -> Void) {
        downloadObservers.append(handler)
    }

    private func emit(_ event: DownloadEvent) {
        for observer in downloadObservers { observer(event) }
    }

    /// The SwiftData models this library stores; add them to the app's container.
    public static var persistentModels: [any PersistentModel.Type] { [InstalledModel.self] }

    public private(set) var catalog: Catalog
    /// Models the user added by ID in this session and has not downloaded yet.
    public private(set) var addedEntries: [CatalogEntry] = []
    public private(set) var installed: [InstalledModel] = []
    public private(set) var downloads: [String: DownloadState] = [:]
    public private(set) var storageUsedBytes: Int64 = 0

    /// The device, with the memory budget measured at launch.
    public let deviceProvider: DeviceProfileProvider

    public func deviceProfile() -> DeviceProfile {
        deviceProvider.current()
    }

    private let context: ModelContext
    private let storage: ModelStorage
    private let downloader: ModelDownloader
    private let hub: HubAPI
    private let catalogLoader: CatalogLoader
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(
        context: ModelContext,
        storage: ModelStorage,
        downloader: ModelDownloader,
        hub: HubAPI = HubAPI(),
        catalogLoader: CatalogLoader,
        deviceProvider: DeviceProfileProvider
    ) throws {
        self.context = context
        self.storage = storage
        self.downloader = downloader
        self.hub = hub
        self.catalogLoader = catalogLoader
        self.deviceProvider = deviceProvider
        self.catalog = try CatalogLoader.bundled()
        reloadInstalled()
    }

    // MARK: Catalog

    public func refreshCatalog() async {
        if let fresh = try? await catalogLoader.load() {
            catalog = fresh
        }
    }

    /// Catalog entries plus models added by ID.
    public var allEntries: [CatalogEntry] {
        catalog.models + addedEntries.filter { added in !catalog.models.contains { $0.id == added.id } }
    }

    public func entry(id: String) -> CatalogEntry? {
        allEntries.first { $0.id == id }
    }

    public func recommendation(appleModel: AppleModelAvailability) -> Recommendation {
        let measurements = Dictionary(
            installed.map { ($0.repoID, $0.measurement) }, uniquingKeysWith: { first, _ in first })
        return ModelRecommender.recommend(
            catalog: catalog.models,
            device: deviceProfile(),
            measurements: measurements,
            installedIDs: Set(installed.map(\.repoID)),
            appleModel: appleModel)
    }

    // MARK: Installed models

    public func installedModel(id: String) -> InstalledModel? {
        installed.first { $0.repoID == id }
    }

    /// Re-reads installed models and storage use. Records whose files are gone are removed.
    public func reloadInstalled() {
        let descriptor = FetchDescriptor<InstalledModel>(sortBy: [SortDescriptor(\.installedAt)])
        let records = (try? context.fetch(descriptor)) ?? []
        for record in records where !storage.isInstalled(record.repoID) {
            context.delete(record)
        }
        try? context.save()
        installed = records.filter { storage.isInstalled($0.repoID) }
        storageUsedBytes = storage.totalBytes()
    }

    public func delete(_ repoID: String) throws {
        tasks[repoID]?.cancel()
        tasks[repoID] = nil
        downloads[repoID] = nil
        try storage.delete(repoID)
        if let record = installedModel(id: repoID) {
            context.delete(record)
            try context.save()
        }
        reloadInstalled()
    }

    /// Stores what a finished reply measured: decode speed (the latest) and memory (the highest).
    public func recordMeasurement(
        for repoID: String, tokensPerSecond: Double?, peakMemoryBytes: Int64?, footprintBytes: Int64?
    ) {
        guard let record = installedModel(id: repoID) else { return }
        if let tokensPerSecond, tokensPerSecond > 0 {
            record.measuredTokensPerSecond = tokensPerSecond
        }
        if let peakMemoryBytes, peakMemoryBytes > (record.measuredPeakMemoryBytes ?? 0) {
            record.measuredPeakMemoryBytes = peakMemoryBytes
            record.measuredFootprintBytes = footprintBytes
        }
        try? context.save()
    }

    /// True while any download is running.
    public var isDownloading: Bool {
        downloads.values.contains { if case .downloading = $0 { true } else { false } }
    }

    // MARK: Downloads

    /// Starts or resumes a download. Call only after the user accepted the model's licence.
    public func download(_ entry: CatalogEntry, licenseAcceptedAt: Date = .now) {
        guard tasks[entry.id] == nil, !storage.isInstalled(entry.id) else { return }
        downloads[entry.id] = .downloading(currentProgress(entry.id))
        emit(.started(entry))
        let downloader = downloader
        // The library lives as long as the app, so the task holds it strongly.
        tasks[entry.id] = Task {
            do {
                _ = try await downloader.download(entry) { progress in
                    Task { @MainActor in self.update(entry.id, progress) }
                }
                finishDownload(entry, licenseAcceptedAt: licenseAcceptedAt)
            } catch is CancellationError {
                endDownload(entry.id, as: .paused(currentProgress(entry.id)))
            } catch {
                endDownload(entry.id, as: .failed(error.localizedDescription))
            }
        }
    }

    /// Stops a download and keeps its bytes, so it can resume.
    public func pause(_ repoID: String) {
        tasks[repoID]?.cancel()
    }

    /// Stops a download and deletes its bytes.
    public func discard(_ repoID: String) {
        tasks[repoID]?.cancel()
        tasks[repoID] = nil
        downloads[repoID] = nil
        emit(.removed(repoID: repoID))
        try? storage.deletePartial(repoID)
        storageUsedBytes = storage.totalBytes()
    }

    private func update(_ repoID: String, _ progress: DownloadProgress) {
        guard case .downloading = downloads[repoID] else { return }
        downloads[repoID] = .downloading(progress)
        emit(.changed(repoID: repoID, .downloading(progress)))
    }

    private func currentProgress(_ repoID: String) -> DownloadProgress? {
        switch downloads[repoID] {
        case .downloading(let progress), .paused(let progress): progress
        case .failed, nil: nil
        }
    }

    private func endDownload(_ repoID: String, as state: DownloadState) {
        // Discarded: `discard` already cleared the task and the state.
        guard tasks[repoID] != nil else { return }
        tasks[repoID] = nil
        downloads[repoID] = state
        emit(.changed(repoID: repoID, state))
        storageUsedBytes = storage.totalBytes()
    }

    private func finishDownload(_ entry: CatalogEntry, licenseAcceptedAt: Date) {
        tasks[entry.id] = nil
        downloads[entry.id] = nil
        if installedModel(id: entry.id) == nil {
            context.insert(InstalledModel(entry: entry, licenseAcceptedAt: licenseAcceptedAt))
            try? context.save()
        }
        addedEntries.removeAll { $0.id == entry.id }
        reloadInstalled()
        emit(.finished(entry))
    }

    // MARK: Add by ID

    /// Looks a model up on Hugging Face and checks it can be used.
    public func inspect(repoID: String) async throws -> AddByID.Result {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await hub.modelInfo(repoID: trimmed)
        return try AddByID.evaluate(repoID: trimmed, info: info, device: deviceProfile())
    }

    /// Lists an inspected model so it can be downloaded like a catalog model.
    public func add(_ entry: CatalogEntry) {
        guard self.entry(id: entry.id) == nil else { return }
        addedEntries.append(entry)
    }
}
