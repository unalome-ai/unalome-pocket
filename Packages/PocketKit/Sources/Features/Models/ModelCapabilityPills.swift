import ModelCatalog
import SwiftUI
import UnalomeDesign

extension CapabilityPills {
    /// The pills for what a model can do on this device.
    init(_ capabilities: ModelCapabilities) {
        self.init(
            capabilities.capabilities.map { capability in
                CapabilityPill.Item(
                    title: capability == .image && capabilities.imageIsTight ? "Image · tight" : capability.title,
                    systemImage: capability.systemImage,
                    isAccented: capability.isAccented)
            },
            accessibilityText: capabilities.accessibilityText)
    }
}

extension ModelLibrary {
    /// A catalog or added model's capabilities on this device (image input only where the
    /// vision model fits the memory budget measured at launch).
    func capabilities(for entry: CatalogEntry) -> ModelCapabilities {
        ModelCapabilities(entry, device: deviceProvider.atLaunch)
    }

    /// An installed model's capabilities, from the catalog when it is listed there.
    func capabilities(for model: InstalledModel) -> ModelCapabilities {
        if let entry = entry(id: model.repoID) {
            return capabilities(for: entry)
        }
        // Added by ID in an earlier session: not checked, so text and voice only.
        return ModelCapabilities(supportsImage: false, supportsThinking: false)
    }
}
