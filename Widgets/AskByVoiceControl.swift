import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center and Lock Screen button that opens a new chat and starts dictation.
struct AskByVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ai.unalome.pocket.ask-by-voice") {
            ControlWidgetButton(action: AskByVoiceIntent()) {
                Label("Ask by voice", systemImage: "mic")
            }
        }
        .displayName("Ask by voice")
        .description("Opens Unalome Pocket and starts on-device dictation.")
    }
}
