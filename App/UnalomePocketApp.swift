import AppleEngine
import ChatCore
import Features
import ModelCatalog
import PocketShared
import SwiftData
import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

@main
struct UnalomePocketApp: App {
    private let container: ModelContainer
    private let services: AppServices
    #if os(iOS)
    private let downloadActivities: DownloadActivities
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            container = try ConversationStore.makeContainer(including: ModelLibrary.persistentModels)
            let storage = try ModelStorage.applicationSupport()
            try storage.prepare()
            let library = try ModelLibrary(
                context: container.mainContext,
                storage: storage,
                downloader: ModelDownloader(storage: storage),
                catalogLoader: CatalogLoader(cacheFile: storage.root.deletingLastPathComponent().appending(path: "catalog-cache.json")),
                // Memory is measured here, at launch, before any model loads.
                deviceProvider: DeviceProfileProvider { DeviceProfile.current(storageDirectory: storage.root) }
            )
            let preferences = AppPreferences(defaults: .standard)
            let canRunLocalModels = !EngineSelection.isSimulator
            let choice = AppServices.initialChoice(
                stored: preferences.selectedEngine,
                installedIDs: Set(library.installed.map(\.repoID)),
                appleModel: AppleChatEngine.availability,
                canRunLocalModels: canRunLocalModels
            )
            let host = EngineHost(choice: choice) { choice in
                EngineSelection.makeEngine(for: choice, storage: storage, library: library)
            }
            services = AppServices(
                host: host,
                library: library,
                preferences: preferences,
                appleModelAvailability: { AppleChatEngine.availability },
                canRunLocalModels: canRunLocalModels,
                attachments: try AttachmentStore.applicationSupport(),
                widgetSnapshots: Self.makeWidgetSnapshots()
            )
            #if os(iOS)
            downloadActivities = DownloadActivities(library: library)
            #endif
        } catch {
            // Without its stores the app can neither show nor save anything.
            fatalError("Could not open the app's storage: \(error)")
        }
    }

    /// The widgets read a small snapshot of the latest chat from the App Group. There are no
    /// widgets on Mac, so nothing is written there.
    private static func makeWidgetSnapshots() -> WidgetSnapshotPublisher? {
        #if os(iOS)
        WidgetSnapshotStore.shared().map {
            WidgetSnapshotPublisher(store: $0) { WidgetCenter.shared.reloadAllTimelines() }
        }
        #else
        nil
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // One window: two windows on one conversation would stream two replies into it.
        Window("Unalome Pocket", id: "main") {
            root
                .frame(minWidth: 720, minHeight: 520)
                .task { MemoryPressure.shared.start { await services.host.unloadForMemoryWarning() } }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .modelContainer(container)
        .commands { PocketCommands() }

        Settings {
            SettingsView(services: services)
                .modelContainer(container)
        }
        #else
        WindowGroup {
            root
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    // Free the model and stop a reply in flight (the chat says why); the next
                    // reply loads it again.
                    Task { await services.host.unloadForMemoryWarning() }
                }
        }
        .modelContainer(container)
        .commands { PocketCommands() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: downloadActivities.didEnterBackground()
            case .active: downloadActivities.didBecomeActive()
            default: break
            }
        }
        #endif
    }

    private var root: some View {
        RootView(services: services)
    }
}

#if os(macOS)
/// The Mac has no memory warning; a critical memory-pressure event frees the model the same way.
@MainActor
private final class MemoryPressure {
    static let shared = MemoryPressure()
    private var source: DispatchSourceMemoryPressure?

    func start(_ handler: @escaping @MainActor () async -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { Task { await handler() } }
        }
        source.resume()
        self.source = source
    }
}
#endif
