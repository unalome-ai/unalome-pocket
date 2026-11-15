import AppleEngine
import ChatCore
import MLXEngine
import ModelCatalog

/// The one place that turns an `EngineChoice` into an engine. Feature code only sees `any ChatEngine`.
enum EngineSelection {
    /// MLX needs a real GPU, so the Simulator always uses the scripted engine.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    @MainActor
    static func makeEngine(for choice: EngineChoice, storage: ModelStorage, library: ModelLibrary) -> any ChatEngine {
        switch choice {
        case .scripted:
            return ScriptedEngine()
        case .appleOnDevice:
            return AppleChatEngine()
        case .localModel(let repoID):
            if isSimulator {
                return ScriptedEngine()
            }
            let name = library.installedModel(id: repoID)?.displayName ?? repoID
            // Thinking support and reasoning delimiters come from the catalog; models added by
            // ID get neither, but `<think>` blocks are still kept out of the reply.
            let entry = library.entry(id: repoID)
            let tags = entry?.reasoningTags.map { ReasoningTags(start: $0.start, end: $0.end) } ?? .think
            return MLXChatEngine(
                directory: storage.directory(for: repoID),
                displayName: name,
                supportsThinking: entry?.supportsThinking ?? false,
                reasoningTags: tags)
        }
    }
}
