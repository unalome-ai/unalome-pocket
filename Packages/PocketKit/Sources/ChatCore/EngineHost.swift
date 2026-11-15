import Foundation
import Observation

/// Which engine the user picked. Stored as a short string (see `rawValue`).
public enum EngineChoice: Hashable, Sendable {
    /// The canned demo engine (Simulator, previews, tests).
    case scripted
    /// Apple's built-in on-device model.
    case appleOnDevice
    /// A downloaded model, identified by its Hugging Face repo ID.
    case localModel(repoID: String)

    public init?(rawValue: String) {
        switch rawValue {
        case "scripted": self = .scripted
        case "apple": self = .appleOnDevice
        default:
            let prefix = "local:"
            guard rawValue.hasPrefix(prefix), rawValue.count > prefix.count else { return nil }
            self = .localModel(repoID: String(rawValue.dropFirst(prefix.count)))
        }
    }

    public var rawValue: String {
        switch self {
        case .scripted: "scripted"
        case .appleOnDevice: "apple"
        case .localModel(let repoID): "local:\(repoID)"
        }
    }
}

/// Owns the one engine the app uses at a time and its load state.
/// Switching engines unloads the previous one first, so only one model is in memory.
@MainActor
@Observable
public final class EngineHost {
    public enum State: Equatable, Sendable {
        case unloaded
        case loading(progress: Double)
        case ready
        case failed(String)
    }

    public private(set) var choice: EngineChoice
    public private(set) var engine: any ChatEngine
    public private(set) var state: State = .unloaded

    private let makeEngine: @MainActor (EngineChoice) -> any ChatEngine
    /// Identifies the current engine; a load that finishes for an older engine is ignored.
    private var generation = 0
    private var loadTask: Task<Void, Error>?

    public init(choice: EngineChoice, makeEngine: @escaping @MainActor (EngineChoice) -> any ChatEngine) {
        self.choice = choice
        self.makeEngine = makeEngine
        self.engine = makeEngine(choice)
    }

    /// Switches to another engine. The current one is unloaded first.
    public func select(_ newChoice: EngineChoice) async {
        guard newChoice != choice else { return }
        let previous = engine
        cancelLoad()
        choice = newChoice
        engine = makeEngine(newChoice)
        state = .unloaded
        await previous.unload()
    }

    /// Loads the current engine if needed. Concurrent callers share one load.
    public func ensureLoaded() async throws {
        if state == .ready { return }
        if let loadTask {
            return try await loadTask.value
        }
        let engine = engine
        let current = generation
        state = .loading(progress: 0)
        // The host lives as long as the app, so the task holds it strongly.
        let task = Task {
            try await engine.load { fraction in
                Task { @MainActor in
                    self.reportProgress(fraction, generation: current)
                }
            }
        }
        loadTask = task
        do {
            try await task.value
            guard current == generation else { throw CancellationError() }
            state = .ready
            loadTask = nil
        } catch {
            guard current == generation else { throw error }
            state = .failed(error.localizedDescription)
            loadTask = nil
            throw error
        }
    }

    /// Frees the model, e.g. on a memory warning. The next reply loads it again.
    public func unload() async {
        cancelLoad()
        state = .unloaded
        await engine.unload()
    }

    private func cancelLoad() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func reportProgress(_ fraction: Double, generation: Int) {
        guard generation == self.generation, case .loading = state else { return }
        state = .loading(progress: min(max(fraction, 0), 1))
    }
}
