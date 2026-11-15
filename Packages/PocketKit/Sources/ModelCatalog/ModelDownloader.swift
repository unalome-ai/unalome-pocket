import CryptoKit
import Foundation
import Synchronization

public struct DownloadProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : 0
    }
}

public enum DownloadError: LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case badStatus(Int)
    case sizeMismatch(file: String)
    case unsafePath(String)
    case checksumMismatch(file: String)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            "Not enough free storage: needs \(ByteFormat.file(needed)), \(ByteFormat.file(available)) available."
        case .badStatus(let status):
            "The download server answered with status \(status)."
        case .sizeMismatch(let file):
            "\(file) did not download completely. Try again."
        case .unsafePath(let path):
            "The model contains an unexpected file path: \(path)"
        case .checksumMismatch(let file):
            "\(file) arrived damaged (its checksum does not match the one Hugging Face publishes) and was deleted. Try the download again."
        }
    }
}

/// Downloads a model's files at its pinned revision into `ModelStorage`.
///
/// Each file is fetched with an HTTP `Range` request starting at the bytes already on disk,
/// so a cancelled, failed or interrupted download resumes where it stopped, also after the
/// app was quit. Downloads run while the app is in the foreground.
public final class ModelDownloader: Sendable {
    /// Free storage that must remain after the download.
    public static let diskHeadroomBytes: Int64 = 512 << 20

    private let storage: ModelStorage
    private let hub: HubAPI
    private let session: URLSession
    private let freeDiskSpace: @Sendable () -> Int64?

    public init(
        storage: ModelStorage,
        hub: HubAPI = HubAPI(),
        session: URLSession = URLSession(configuration: .default),
        freeDiskSpace: (@Sendable () -> Int64?)? = nil
    ) {
        self.storage = storage
        self.hub = hub
        self.session = session
        self.freeDiskSpace = freeDiskSpace ?? { [root = storage.root] in DeviceProfile.freeDiskSpace(at: root) }
    }

    /// Downloads (or resumes) `entry` and returns the folder of the finished model.
    /// Cancelling the calling task stops the download and keeps what has arrived so far.
    public func download(
        _ entry: CatalogEntry,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let info = try await hub.modelInfo(repoID: entry.id, revision: entry.revision)
        let files = info.modelFiles
        for file in files where !Self.isSafe(file.path) {
            throw DownloadError.unsafePath(file.path)
        }
        let total = files.reduce(0) { $0 + ($1.size ?? 0) }
        let partial = storage.partialDirectory(for: entry.id)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try storage.prepare()

        let alreadyThere = storage.partialBytes(for: entry.id, files: files)
        let needed = max(total - alreadyThere, 0) + Self.diskHeadroomBytes
        if let available = freeDiskSpace(), needed > available {
            throw DownloadError.notEnoughSpace(needed: needed, available: available)
        }

        let reporter = ThrottledProgress(total: total, report: progress)
        var finishedBytes: Int64 = 0
        for file in files {
            let target = partial.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let expected = file.size, ModelStorage.fileSize(target) > expected {
                try FileManager.default.removeItem(at: target)
            }
            if file.size == nil || ModelStorage.fileSize(target) < (file.size ?? 0) {
                let base = finishedBytes
                try await FileFetcher.fetch(
                    url: hub.fileURL(repoID: entry.id, revision: entry.revision, path: file.path),
                    to: target,
                    session: session
                ) { bytesInFile in
                    reporter.update(base + bytesInFile)
                }
            }
            let size = ModelStorage.fileSize(target)
            if let expected = file.size, size != expected {
                throw DownloadError.sizeMismatch(file: file.path)
            }
            if let expected = file.sha256 {
                try Task.checkCancellation()
                guard try Self.sha256(of: target) == expected else {
                    try? FileManager.default.removeItem(at: target)
                    throw DownloadError.checksumMismatch(file: file.path)
                }
            }
            finishedBytes += size
            reporter.update(finishedBytes)
        }
        reporter.finish(finishedBytes)

        let destination = storage.directory(for: entry.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// Lowercase hex SHA-256 of a file, read in 4 MB chunks so a multi-gigabyte weights file
    /// never sits in memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Repo-relative paths only: no absolute paths, no `..`.
    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

/// Reports progress at most every 100 ms, so observers are not flooded.
private final class ThrottledProgress: Sendable {
    private let total: Int64
    private let report: @Sendable (DownloadProgress) -> Void
    private let lastReport = Mutex<ContinuousClock.Instant?>(nil)

    init(total: Int64, report: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.report = report
    }

    func update(_ completed: Int64) {
        let now = ContinuousClock.now
        let due = lastReport.withLock { last in
            guard last.map({ now - $0 >= .milliseconds(100) }) ?? true else { return false }
            last = now
            return true
        }
        if due {
            report(DownloadProgress(completedBytes: completed, totalBytes: total))
        }
    }

    func finish(_ completed: Int64) {
        report(DownloadProgress(completedBytes: completed, totalBytes: total))
    }
}

/// Appends one HTTP response body to a file, asking only for the bytes the file does not have yet.
final class FileFetcher: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var handle: FileHandle?
        var bytesInFile: Int64
        var continuation: CheckedContinuation<Void, Error>?
        var failure: Error?
    }

    private let state: Mutex<State>
    private let onProgress: @Sendable (Int64) -> Void

    private init(file: URL, onProgress: @escaping @Sendable (Int64) -> Void) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        let offset = try handle.seekToEnd()
        state = Mutex(State(handle: handle, bytesInFile: Int64(offset)))
        self.onProgress = onProgress
    }

    static func fetch(
        url: URL,
        to file: URL,
        session: URLSession,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let fetcher = try FileFetcher(file: file, onProgress: onProgress)
        var request = URLRequest(url: url)
        request.setValue("UnalomePocket", forHTTPHeaderField: "User-Agent")
        let offset = fetcher.state.withLock { $0.bytesInFile }
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        task.delegate = fetcher
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetcher.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let disposition: URLSession.ResponseDisposition = state.withLock { state in
            switch status {
            case 206:
                return .allow
            case 200:
                // The server sent the whole file, so start the file over.
                do {
                    try state.handle?.truncate(atOffset: 0)
                    state.bytesInFile = 0
                    return .allow
                } catch {
                    state.failure = error
                    return .cancel
                }
            default:
                state.failure = DownloadError.badStatus(status)
                return .cancel
            }
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let written: Int64? = state.withLock { state in
            do {
                try state.handle?.write(contentsOf: data)
                state.bytesInFile += Int64(data.count)
                return state.bytesInFile
            } catch {
                state.failure = error
                return nil
            }
        }
        if let written {
            onProgress(written)
        } else {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome): (CheckedContinuation<Void, Error>?, Error?) = state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.failure ?? error)
        }
        if let outcome {
            let cancelled = (outcome as? URLError)?.code == .cancelled
            continuation?.resume(throwing: cancelled ? CancellationError() : outcome)
        } else {
            continuation?.resume()
        }
    }
}
