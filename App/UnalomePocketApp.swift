import AppleEngine
import ChatCore
import Features
import ModelCatalog
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct UnalomePocketApp: App {
    private let container: ModelContainer
    private let services: AppServices

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
                attachments: try AttachmentStore.applicationSupport()
            )
        } catch {
            // Without its stores the app can neither show nor save anything.
            fatalError("Could not open the app's storage: \(error)")
        }
    }

    var body: some Scene {
        #if os(macOS)
        // One window: two windows on one conversation would stream two replies into it.
        Window("Unalome Pocket", id: "main") {
            root
        }
        .modelContainer(container)
        #else
        WindowGroup {
            root
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    // Free the model; the next reply loads it again.
                    Task { await services.host.unload() }
                }
        }
        .modelContainer(container)
        #endif
    }

    private var root: some View {
        RootView(services: services)
    }
}
