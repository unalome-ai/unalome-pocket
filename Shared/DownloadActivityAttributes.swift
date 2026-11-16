#if os(iOS)
import ActivityKit
import PocketShared

/// The Live Activity for a model download. Shared by the app (which starts and updates it)
/// and the widget extension (which draws it).
struct DownloadActivityAttributes: ActivityAttributes {
    typealias ContentState = DownloadActivityContent

    var modelName: String
    var totalBytes: Int64
}
#endif
