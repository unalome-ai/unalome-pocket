import PocketShared
import Testing
@testable import ModelCatalog

struct DownloadActivityMappingTests {
    @Test func mapsDownloaderProgressToActivityContent() {
        let progress = DownloadProgress(completedBytes: 300, totalBytes: 1200)
        let downloading = ModelLibrary.DownloadState.downloading(progress).activityContent(totalBytes: 1000)
        #expect(downloading == DownloadActivityContent(bytesDone: 300, totalBytes: 1200, phase: .downloading))
        #expect(downloading.fraction == 0.25)

        let verifying = ModelLibrary.DownloadState
            .downloading(DownloadProgress(completedBytes: 1200, totalBytes: 1200, isVerifying: true))
            .activityContent(totalBytes: 1000)
        #expect(verifying.phase == .verifying)

        // Before the first report the catalog size stands in.
        let starting = ModelLibrary.DownloadState.downloading(nil).activityContent(totalBytes: 1000)
        #expect(starting == DownloadActivityContent(bytesDone: 0, totalBytes: 1000, phase: .downloading))
    }

    @Test func mapsPauseFailureAndFinish() {
        let progress = DownloadProgress(completedBytes: 400, totalBytes: 1000)
        let paused = ModelLibrary.DownloadState.paused(progress).activityContent(totalBytes: 1000)
        #expect(paused.phase == .paused && !paused.pausedForBackground && paused.bytesDone == 400)
        let background = ModelLibrary.DownloadState.paused(progress)
            .activityContent(totalBytes: 1000, pausedForBackground: true)
        #expect(background.pausedForBackground)
        #expect(background.statusText.contains("open the app"))
        // Only a pause can be a background pause.
        #expect(!ModelLibrary.DownloadState.downloading(progress).activityContent(totalBytes: 1000, pausedForBackground: true).pausedForBackground)

        let failed = ModelLibrary.DownloadState.failed("Checksum").activityContent(totalBytes: 1000)
        #expect(failed.phase == .failed && failed.isFinal)
        #expect(DownloadActivityContent.finished(totalBytes: 1000).fraction == 1)
    }
}
