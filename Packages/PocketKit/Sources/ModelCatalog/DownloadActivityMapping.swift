import Foundation
import PocketShared

extension ModelLibrary.DownloadState {
    /// The Live Activity content for this download state. `totalBytes` is the catalog size,
    /// used until the downloader reports the real total.
    public func activityContent(totalBytes: Int64, pausedForBackground: Bool = false) -> DownloadActivityContent {
        func content(_ progress: DownloadProgress?, _ phase: DownloadActivityContent.Phase) -> DownloadActivityContent {
            let total = (progress?.totalBytes ?? 0) > 0 ? progress?.totalBytes ?? totalBytes : totalBytes
            return DownloadActivityContent(
                bytesDone: min(progress?.completedBytes ?? 0, total), totalBytes: total, phase: phase,
                pausedForBackground: phase == .paused && pausedForBackground)
        }
        switch self {
        case .downloading(let progress):
            return content(progress, progress?.isVerifying == true ? .verifying : .downloading)
        case .paused(let progress):
            return content(progress, .paused)
        case .failed:
            return DownloadActivityContent(bytesDone: 0, totalBytes: totalBytes, phase: .failed)
        }
    }
}

extension DownloadActivityContent {
    /// The final content when a download finished and the model was installed.
    public static func finished(totalBytes: Int64) -> DownloadActivityContent {
        DownloadActivityContent(bytesDone: totalBytes, totalBytes: totalBytes, phase: .done)
    }
}
