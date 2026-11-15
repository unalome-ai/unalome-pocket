import Foundation

/// Where model files live: `Application Support/Models`, excluded from iCloud backup.
///
///     Models/installed/<org>/<repo>/…   finished downloads, ready to load
///     Models/partial/<org>/<repo>/…     downloads in progress, kept so they can resume
public struct ModelStorage: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The app's standard location.
    public static func applicationSupport() throws -> ModelStorage {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ModelStorage(root: base.appending(path: "Models", directoryHint: .isDirectory))
    }

    /// Creates the root folder if needed and excludes it (and so everything in it) from backup.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    public func directory(for repoID: String) -> URL {
        root.appending(path: "installed").appending(path: repoID, directoryHint: .isDirectory)
    }

    func partialDirectory(for repoID: String) -> URL {
        root.appending(path: "partial").appending(path: repoID, directoryHint: .isDirectory)
    }

    public func isInstalled(_ repoID: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: repoID).appending(path: "config.json").path)
    }

    /// Removes a model's files, finished or partial.
    public func delete(_ repoID: String) throws {
        for url in [directory(for: repoID), partialDirectory(for: repoID)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Removes a partial download only.
    public func deletePartial(_ repoID: String) throws {
        let url = partialDirectory(for: repoID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Bytes on disk under the root, including partial downloads.
    public func totalBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Bytes already present for each file of a partial download.
    func partialBytes(for repoID: String, files: [HubModelInfo.File]) -> Int64 {
        let directory = partialDirectory(for: repoID)
        return files.reduce(0) { sum, file in
            sum + Self.fileSize(directory.appending(path: file.path))
        }
    }

    /// Reads the size from the file system each time. (`URL.resourceValues` caches values on
    /// the URL, which would report a stale size for a file that is still being written.)
    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
