import SwiftUI
import WidgetKit

@main
struct PocketWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ChatWidget()
        AskByVoiceControl()
        DownloadLiveActivity()
    }
}
