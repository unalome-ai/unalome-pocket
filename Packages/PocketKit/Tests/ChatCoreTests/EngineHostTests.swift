import Foundation
import Synchronization
import Testing
@testable import ChatCore

/// Records loads and unloads; can fail its first load.
private final class RecordingEngine: ChatEngine {
    struct Counts: Equatable {
        var loads = 0
        var unloads = 0
    }

    let displayName: String
    let capabilities = EngineCapabilities(supportsVision: false, maxContextTokens: 1024)
    let counts = Mutex(Counts())
    private let failFirstLoad: Bool
    private let loadDelay: Duration

    init(name: String, failFirstLoad: Bool = false, loadDelay: Duration = .milliseconds(30)) {
        displayName = name
        self.failFirstLoad = failFirstLoad
        self.loadDelay = loadDelay
    }

    struct LoadFailed: Error {}

    func load(progress: @Sendable (Double) -> Void) async throws {
        let attempt = counts.withLock { counts in
            counts.loads += 1
            return counts.loads
        }
        progress(0.5)
        try await Task.sleep(for: loadDelay)
        if failFirstLoad && attempt == 1 {
            throw LoadFailed()
        }
        progress(1)
    }

    func unload() async {
        counts.withLock { $0.unloads += 1 }
    }

    func reply(to turn: ChatTurn, history: [ChatTurn], options: GenerationOptions)
        -> AsyncThrowingStream<GenerationEvent, Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
struct EngineHostTests {
    @Test(arguments: [EngineChoice.scripted, .appleOnDevice, .localModel(repoID: "mlx-community/Qwen3.5-0.8B-4bit")])
    func choiceRoundTripsThroughRawValue(_ choice: EngineChoice) {
        #expect(EngineChoice(rawValue: choice.rawValue) == choice)
    }

    @Test func rejectsUnknownRawValues() {
        #expect(EngineChoice(rawValue: "") == nil)
        #expect(EngineChoice(rawValue: "local:") == nil)
        #expect(EngineChoice(rawValue: "cloud") == nil)
    }

    @Test func concurrentCallersShareOneLoad() async throws {
        let engine = RecordingEngine(name: "a")
        let host = EngineHost(choice: .scripted) { _ in engine }
        #expect(host.state == .unloaded)

        async let first: Void = host.ensureLoaded()
        async let second: Void = host.ensureLoaded()
        _ = try await (first, second)
        try await host.ensureLoaded()

        #expect(host.state == .ready)
        #expect(engine.counts.withLock { $0.loads } == 1)
    }

    @Test func selectingAnotherEngineUnloadsThePreviousOne() async throws {
        let engines = ["scripted": RecordingEngine(name: "s"), "apple": RecordingEngine(name: "a")]
        let host = EngineHost(choice: .scripted) { choice in engines[choice.rawValue] ?? RecordingEngine(name: "?") }
        try await host.ensureLoaded()

        await host.select(.appleOnDevice)

        #expect(host.choice == .appleOnDevice)
        #expect(host.engine.displayName == "a")
        #expect(host.state == .unloaded)
        #expect(engines["scripted"]?.counts.withLock { $0.unloads } == 1)
        #expect(engines["apple"]?.counts.withLock { $0.loads } == 0)
    }

    @Test func selectingTheSameEngineKeepsItLoaded() async throws {
        let engine = RecordingEngine(name: "a")
        let host = EngineHost(choice: .scripted) { _ in engine }
        try await host.ensureLoaded()
        await host.select(.scripted)
        #expect(host.state == .ready)
        #expect(engine.counts.withLock { $0.unloads } == 0)
    }

    @Test func failedLoadIsReportedAndCanBeRetried() async throws {
        let engine = RecordingEngine(name: "a", failFirstLoad: true)
        let host = EngineHost(choice: .scripted) { _ in engine }

        await #expect(throws: RecordingEngine.LoadFailed.self) { try await host.ensureLoaded() }
        guard case .failed = host.state else {
            Issue.record("expected .failed, got \(host.state)")
            return
        }

        try await host.ensureLoaded()
        #expect(host.state == .ready)
        #expect(engine.counts.withLock { $0.loads } == 2)
    }

    @Test func switchingDuringLoadDiscardsTheOldLoad() async throws {
        let slow = RecordingEngine(name: "slow", loadDelay: .milliseconds(300))
        let fast = RecordingEngine(name: "fast")
        let host = EngineHost(choice: .scripted) { $0 == .scripted ? slow : fast }

        let pending = Task { try await host.ensureLoaded() }
        try await Task.sleep(for: .milliseconds(20))
        await host.select(.appleOnDevice)
        _ = await pending.result

        #expect(host.choice == .appleOnDevice)
        #expect(host.state == .unloaded)
        try await host.ensureLoaded()
        #expect(host.state == .ready)
        #expect(host.engine.displayName == "fast")
    }

    @Test func unloadFreesTheEngine() async throws {
        let engine = RecordingEngine(name: "a")
        let host = EngineHost(choice: .scripted) { _ in engine }
        try await host.ensureLoaded()

        await host.unload()

        #expect(host.state == .unloaded)
        #expect(engine.counts.withLock { $0.unloads } == 1)
        try await host.ensureLoaded()
        #expect(engine.counts.withLock { $0.loads } == 2)
    }
}
