import Foundation

/// The changing part of the model-download Live Activity. Kept free of ActivityKit so it can be
/// built and tested anywhere; the app and widget wrap it in `ActivityAttributes`.
public struct DownloadActivityContent: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case downloading
        /// Stopped; the bytes so far are kept. `pausedForBackground` says why.
        case paused
        /// Checking the downloaded files against Hugging Face's checksums.
        case verifying
        case done
        case failed
    }

    public var bytesDone: Int64
    public var totalBytes: Int64
    public var phase: Phase
    /// Paused because the app went to the background (shows "open the app to continue").
    public var pausedForBackground: Bool

    public init(bytesDone: Int64, totalBytes: Int64, phase: Phase, pausedForBackground: Bool = false) {
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.phase = phase
        self.pausedForBackground = pausedForBackground
    }

    public var fraction: Double {
        if phase == .done { return 1 }
        return totalBytes > 0 ? min(max(Double(bytesDone) / Double(totalBytes), 0), 1) : 0
    }

    public var percentText: String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }

    /// One short line for the Lock Screen and the expanded Dynamic Island.
    public var statusText: String {
        switch phase {
        case .downloading: "Downloading"
        case .paused: pausedForBackground ? "Paused — open the app to continue" : "Paused"
        case .verifying: "Checking the files"
        case .done: "Ready to use"
        case .failed: "Download failed — open the app to retry"
        }
    }

    /// The activity has ended for good.
    public var isFinal: Bool {
        phase == .done || phase == .failed
    }
}

/// Decides when to push an update to the Live Activity: at most about once a second, but always
/// at once when the phase changes. ActivityKit throttles frequent updates itself; this keeps the
/// app from asking.
public struct ActivityUpdateThrottle: Sendable {
    public let interval: TimeInterval
    private var lastSent: (date: Date, phase: DownloadActivityContent.Phase, paused: Bool)?

    public init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    public mutating func shouldSend(_ content: DownloadActivityContent, at now: Date) -> Bool {
        if let last = lastSent, last.phase == content.phase, last.paused == content.pausedForBackground,
           now.timeIntervalSince(last.date) < interval {
            return false
        }
        lastSent = (now, content.phase, content.pausedForBackground)
        return true
    }
}
