import ChatCore
import Foundation
import ModelCatalog
import Observation

/// Small user settings kept in `UserDefaults`.
@MainActor
@Observable
public final class AppPreferences {
    private enum Key {
        static let onboarding = "hasCompletedOnboarding"
        static let engine = "selectedEngine"
    }

    @ObservationIgnored public let defaults: UserDefaults

    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) }
    }

    public var selectedEngine: EngineChoice? {
        didSet { defaults.set(selectedEngine?.rawValue, forKey: Key.engine) }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        selectedEngine = defaults.string(forKey: Key.engine).flatMap(EngineChoice.init(rawValue:))
    }
}

/// Everything the feature screens need from the app, passed down explicitly.
@MainActor
public struct AppServices {
    public let host: EngineHost
    public let library: ModelLibrary
    public let preferences: AppPreferences
    public let appleModelAvailability: @MainActor () -> AppleModelAvailability
    /// `false` in the Simulator, where downloaded models cannot run (MLX needs a real GPU).
    public let canRunLocalModels: Bool
    /// Where attached images are stored; `nil` turns image input off.
    public let attachments: AttachmentStore?

    public init(
        host: EngineHost,
        library: ModelLibrary,
        preferences: AppPreferences,
        appleModelAvailability: @escaping @MainActor () -> AppleModelAvailability,
        canRunLocalModels: Bool,
        attachments: AttachmentStore? = nil
    ) {
        self.host = host
        self.library = library
        self.preferences = preferences
        self.appleModelAvailability = appleModelAvailability
        self.canRunLocalModels = canRunLocalModels
        self.attachments = attachments
    }

    /// The engine to start with: the stored choice if it can still be used, otherwise an installed
    /// model, then Apple's model, then the scripted demo.
    public static func initialChoice(
        stored: EngineChoice?,
        installedIDs: Set<String>,
        appleModel: AppleModelAvailability,
        canRunLocalModels: Bool
    ) -> EngineChoice {
        switch stored {
        case .localModel(let repoID) where canRunLocalModels && installedIDs.contains(repoID):
            return .localModel(repoID: repoID)
        case .appleOnDevice where appleModel.isAvailable:
            return .appleOnDevice
        case .scripted where !canRunLocalModels:
            return .scripted
        default:
            break
        }
        if canRunLocalModels, let repoID = installedIDs.sorted().first {
            return .localModel(repoID: repoID)
        }
        return appleModel.isAvailable ? .appleOnDevice : .scripted
    }

    /// Switches the chat engine and remembers the choice.
    public func select(_ choice: EngineChoice) async {
        preferences.selectedEngine = choice
        await host.select(choice)
    }

    /// The engines the user can pick right now, for the model pill.
    public func engineOptions() -> [EngineOption] {
        var options = library.installed.map { model in
            EngineOption(
                choice: .localModel(repoID: model.repoID),
                title: model.displayName,
                detail: canRunLocalModels ? ByteFormat.file(model.sizeBytes) : "Runs on a real device only",
                isEnabled: canRunLocalModels)
        }
        let apple = appleModelAvailability()
        options.append(
            EngineOption(
                choice: .appleOnDevice,
                title: "Apple on-device model",
                detail: apple.isAvailable ? "Built in, no download" : apple.explanation,
                isEnabled: apple.isAvailable))
        if !canRunLocalModels {
            options.append(
                EngineOption(choice: .scripted, title: "Scripted demo", detail: "Canned replies", isEnabled: true))
        }
        return options
    }

    /// Deletes a model's files. If it is in use, the chat switches to another engine first.
    public func deleteModel(_ repoID: String) async throws {
        if host.choice == .localModel(repoID: repoID) {
            await select(fallbackChoice(excluding: repoID))
        }
        try library.delete(repoID)
    }

    /// The engine to use when the selected one goes away.
    public func fallbackChoice(excluding repoID: String? = nil) -> EngineChoice {
        if canRunLocalModels, let other = library.installed.first(where: { $0.repoID != repoID }) {
            return .localModel(repoID: other.repoID)
        }
        if appleModelAvailability().isAvailable {
            return .appleOnDevice
        }
        return .scripted
    }

    /// Records what a finished reply measured against the model that produced it.
    func record(_ metrics: ReplyMetrics, for choice: EngineChoice) {
        if case .localModel(let repoID) = choice {
            library.recordMeasurement(
                for: repoID,
                tokensPerSecond: metrics.tokensPerSecond,
                peakMemoryBytes: metrics.memory?.peakBytes,
                footprintBytes: metrics.memory?.processFootprintBytes)
        }
    }
}

public struct EngineOption: Identifiable, Equatable {
    public var id: String { choice.rawValue }
    public var choice: EngineChoice
    public var title: String
    public var detail: String
    public var isEnabled: Bool
}
