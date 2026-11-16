#if os(iOS)
import ActivityKit
import BackgroundTasks
import Foundation
import ModelCatalog
import PocketShared

/// Shows model downloads on the Lock Screen and Dynamic Island, and keeps them going in the
/// background.
///
/// Each download asks for a continued-processing task (iOS 26), which lets it run after the
/// user leaves the app, with the system's own progress UI. If the system declines or later
/// expires the task, the download is paused when the app goes to the background, the Live
/// Activity says "Paused — open the app to continue", and it resumes when the app returns.
@MainActor
final class DownloadActivities {
    /// The prefix of the identifiers registered in `BGTaskSchedulerPermittedIdentifiers`.
    static let taskIdentifierPrefix = "ai.unalome.pocket.download."

    private struct Download {
        var entry: CatalogEntry
        var activity: Activity<DownloadActivityAttributes>?
        var throttle = ActivityUpdateThrottle()
        var backgroundTask: BGContinuedProcessingTask?
        var pausedForBackground = false
        var content: DownloadActivityContent
    }

    private let library: ModelLibrary
    private var downloads: [String: Download] = [:]
    private var isInBackground = false

    init(library: ModelLibrary) {
        self.library = library
        library.observeDownloads { [weak self] event in
            self?.handle(event)
        }
    }

    // MARK: App lifecycle

    /// The app went to the background: downloads without a continued-processing task pause
    /// (a suspended app would lose them mid-file) and resume on return.
    func didEnterBackground() {
        isInBackground = true
        for (repoID, download) in downloads where download.backgroundTask == nil && download.content.phase == .downloading {
            downloads[repoID]?.pausedForBackground = true
            library.pause(repoID)
        }
    }

    func didBecomeActive() {
        isInBackground = false
        for (repoID, download) in downloads where download.pausedForBackground {
            downloads[repoID]?.pausedForBackground = false
            library.download(download.entry)
        }
    }

    // MARK: Events

    private func handle(_ event: ModelLibrary.DownloadEvent) {
        switch event {
        case .started(let entry):
            start(entry)
        case .changed(let repoID, let state):
            guard var download = downloads[repoID] else { return }
            download.content = state.activityContent(
                totalBytes: download.entry.downloadSizeBytes, pausedForBackground: download.pausedForBackground)
            downloads[repoID] = download
            report(repoID)
            switch state {
            case .downloading:
                break
            case .paused:
                // A user pause, an expired background task or a background pause: the system
                // task ends; the Live Activity stays, showing the bytes kept.
                completeBackgroundTask(repoID, success: false)
            case .failed:
                finish(repoID, content: download.content, dismissal: .default)
            }
        case .finished(let entry):
            guard downloads[entry.id] != nil else { return }
            finish(entry.id, content: .finished(totalBytes: entry.downloadSizeBytes), dismissal: .default)
        case .removed(let repoID):
            guard let download = downloads[repoID] else { return }
            finish(repoID, content: download.content, dismissal: .immediate)
        }
    }

    private func start(_ entry: CatalogEntry) {
        let content = ModelLibrary.DownloadState.downloading(nil).activityContent(totalBytes: entry.downloadSizeBytes)
        if downloads[entry.id] == nil {
            downloads[entry.id] = Download(entry: entry, content: content)
        } else {
            // Resumed: keep the activity, start a new background task.
            downloads[entry.id]?.content = content
            downloads[entry.id]?.throttle = ActivityUpdateThrottle()
        }
        if downloads[entry.id]?.activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = DownloadActivityAttributes(modelName: entry.displayName, totalBytes: entry.downloadSizeBytes)
            downloads[entry.id]?.activity = try? Activity.request(
                attributes: attributes, content: ActivityContent(state: content, staleDate: nil))
        }
        report(entry.id)
        requestBackgroundTask(for: entry)
    }

    /// Sends the content to the Live Activity (about once a second) and the background task.
    private func report(_ repoID: String) {
        guard var download = downloads[repoID] else { return }
        let content = download.content
        if let task = download.backgroundTask {
            task.progress.totalUnitCount = max(content.totalBytes, 1)
            task.progress.completedUnitCount = content.bytesDone
        }
        if let activity = download.activity, download.throttle.shouldSend(content, at: .now) {
            let box = ActivityBox(activity)
            Task { await box.activity.update(ActivityContent(state: content, staleDate: nil)) }
        }
        downloads[repoID] = download
    }

    private func finish(_ repoID: String, content: DownloadActivityContent, dismissal: ActivityUIDismissalPolicy) {
        completeBackgroundTask(repoID, success: content.phase == .done)
        if let activity = downloads[repoID]?.activity {
            let box = ActivityBox(activity)
            Task { await box.activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: dismissal) }
        }
        downloads[repoID] = nil
    }

    // MARK: Continued processing

    private func requestBackgroundTask(for entry: CatalogEntry) {
        // A fresh identifier per request: registering one twice stops the app.
        let identifier = Self.taskIdentifierPrefix + UUID().uuidString
        let repoID = entry.id
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task, to: repoID)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Downloading \(entry.displayName)",
            subtitle: "Unalome Pocket")
        // Run now or not at all: a queued request would start after the download it was for.
        request.strategy = .fail
        // Declined (busy system, or not supported): the background pause covers it.
        if #available(iOS 27.0, *) {
            Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
        } else {
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    private func attach(_ task: BGContinuedProcessingTask, to repoID: String) {
        guard downloads[repoID] != nil, downloads[repoID]?.content.phase == .downloading else {
            task.setTaskCompleted(success: false)
            return
        }
        downloads[repoID]?.backgroundTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                // Out of background time: pause, and resume when the app returns.
                guard let self, self.downloads[repoID] != nil else { return }
                self.downloads[repoID]?.backgroundTask = nil
                if self.isInBackground {
                    self.downloads[repoID]?.pausedForBackground = true
                    self.library.pause(repoID)
                }
                task.setTaskCompleted(success: false)
            }
        }
        report(repoID)
    }

    private func completeBackgroundTask(_ repoID: String, success: Bool) {
        guard let task = downloads[repoID]?.backgroundTask else { return }
        downloads[repoID]?.backgroundTask = nil
        task.setTaskCompleted(success: success)
    }
}
/// Carries an activity into the task that updates it. ActivityKit's `Activity` is safe to use
/// from any thread but is not marked `Sendable`.
private struct ActivityBox: @unchecked Sendable {
    let activity: Activity<DownloadActivityAttributes>
    init(_ activity: Activity<DownloadActivityAttributes>) { self.activity = activity }
}
#endif
