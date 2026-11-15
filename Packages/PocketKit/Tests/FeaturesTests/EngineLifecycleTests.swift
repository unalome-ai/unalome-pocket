import ChatCore
import Foundation
import ModelCatalog
import SwiftData
import Synchronization
import Testing
@testable import Features

/// Replies only once loaded, and loads slowly enough to observe the loading state.
private final class SlowLoadingEngine: ChatEngine {
    let displayName = "Slow"
    let capabilities = EngineCapabilities(supportsVision: false, maxContextTokens: 1024)
    let loaded = Mutex(false)

    func load(progress: @Sendable (Double) -> Void) async throws {
        progress(0)
        try await Task.sleep(for: .milliseconds(150))
        loaded.withLock { $0 = true }
        progress(1)
    }

    func unload() async {
        loaded.withLock { $0 = false }
    }

    func reply(to turn: ChatTurn, history: [ChatTurn], options: GenerationOptions)
        -> AsyncThrowingStream<GenerationEvent, Error>
    {
        let isLoaded = loaded.withLock { $0 }
        return AsyncThrowingStream { continuation in
            guard isLoaded else {
                continuation.finish(throwing: NotLoaded())
                return
            }
            continuation.yield(.token("loaded reply"))
            continuation.yield(.stats(tokensPerSecond: 12))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private struct NotLoaded: Error {}

@MainActor
struct EngineLifecycleTests {
    @Test func firstReplyWaitsForTheModelToLoad() async throws {
        let container = try ConversationStore.makeContainer(inMemory: true)
        let store = ConversationStore(context: container.mainContext)
        let conversation = try store.createConversation()
        let host = EngineHost(choice: .localModel(repoID: "a/b")) { _ in SlowLoadingEngine() }
        let model = ChatViewModel(conversation: conversation, store: store, host: host)
        var finished: [(EngineChoice, ReplyMetrics)] = []
        model.onReplyFinished = { finished.append(($0, $1)) }

        model.draft = "Hi"
        model.send()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.isLoadingModel)

        await model.waitForGeneration()

        #expect(model.errorMessage == nil)
        #expect(host.state == .ready)
        #expect(model.messages.last?.text == "loaded reply")
        #expect(finished.count == 1)
        #expect(finished.first?.0 == .localModel(repoID: "a/b"))
        #expect(finished.first?.1.tokensPerSecond == 12)
    }

    @Test func initialChoiceKeepsAUsableStoredChoice() {
        let local = EngineChoice.localModel(repoID: "a/b")
        #expect(
            AppServices.initialChoice(
                stored: local, installedIDs: ["a/b"], appleModel: .available, canRunLocalModels: true) == local)
        #expect(
            AppServices.initialChoice(
                stored: .appleOnDevice, installedIDs: ["a/b"], appleModel: .available, canRunLocalModels: true)
                == .appleOnDevice)
    }

    @Test func initialChoiceFallsBackWhenTheStoredChoiceIsGone() {
        // Model deleted: use another installed one.
        #expect(
            AppServices.initialChoice(
                stored: .localModel(repoID: "gone/model"), installedIDs: ["a/b"], appleModel: .available,
                canRunLocalModels: true) == .localModel(repoID: "a/b"))
        // Apple Intelligence turned off, nothing installed: scripted demo.
        #expect(
            AppServices.initialChoice(
                stored: .appleOnDevice, installedIDs: [], appleModel: .appleIntelligenceNotEnabled,
                canRunLocalModels: true) == .scripted)
        // First run on a device with Apple Intelligence.
        #expect(
            AppServices.initialChoice(
                stored: nil, installedIDs: [], appleModel: .available, canRunLocalModels: true) == .appleOnDevice)
    }

    @Test func simulatorNeverPicksADownloadedModel() {
        #expect(
            AppServices.initialChoice(
                stored: .localModel(repoID: "a/b"), installedIDs: ["a/b"], appleModel: .deviceNotEligible,
                canRunLocalModels: false) == .scripted)
    }

    @Test func preferencesPersist() throws {
        let suite = "PocketKitTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.hasCompletedOnboarding)
        #expect(preferences.selectedEngine == nil)
        preferences.hasCompletedOnboarding = true
        preferences.selectedEngine = .localModel(repoID: "a/b")

        let reloaded = AppPreferences(defaults: defaults)
        #expect(reloaded.hasCompletedOnboarding)
        #expect(reloaded.selectedEngine == .localModel(repoID: "a/b"))
    }
}
