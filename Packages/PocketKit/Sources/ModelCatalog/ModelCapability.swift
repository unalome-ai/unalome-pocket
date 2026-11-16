import Foundation

/// Something a model can do, shown as a pill on the Models list.
public enum ModelCapability: String, CaseIterable, Sendable {
    case text, image, voice, thinking

    /// Sentence case, as shown.
    public var title: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .voice: "Voice"
        case .thinking: "Thinking"
        }
    }

    public var systemImage: String {
        switch self {
        case .text: "text.bubble"
        case .image: "photo"
        case .voice: "mic"
        case .thinking: "brain"
        }
    }

    /// Image and thinking set models apart; text and voice every model has.
    public var isAccented: Bool {
        self == .image || self == .thinking
    }
}

/// What a model can do, in display order: text (always), image, voice (always, through
/// on-device dictation), thinking. Pure.
public struct ModelCapabilities: Equatable, Sendable {
    public var capabilities: [ModelCapability]
    /// Images fit on this device, but close to the memory limit.
    public var imageIsTight: Bool

    public init(supportsImage: Bool, supportsThinking: Bool, imageIsTight: Bool = false) {
        var capabilities: [ModelCapability] = [.text]
        if supportsImage { capabilities.append(.image) }
        capabilities.append(.voice)
        if supportsThinking { capabilities.append(.thinking) }
        self.capabilities = capabilities
        self.imageIsTight = supportsImage && imageIsTight
    }

    /// A catalog entry. With a device, image input is shown only if the vision model fits on
    /// it (see `ModelRecommender.imageUse`). Models added by ID were not checked, so they show
    /// text and voice only.
    public init(_ entry: CatalogEntry, device: DeviceProfile? = nil) {
        guard entry.isVerified else {
            self.init(supportsImage: false, supportsThinking: false)
            return
        }
        let imageUse = device.map { ModelRecommender.imageUse(entry, device: $0) }
            ?? (entry.supportsVision ? .fits : .unsupported)
        self.init(
            supportsImage: imageUse == .fits || imageUse == .tight,
            supportsThinking: entry.supportsThinking,
            imageIsTight: imageUse == .tight)
    }

    /// Apple's built-in model: text only, no reasoning switch.
    public static let appleOnDevice = ModelCapabilities(supportsImage: false, supportsThinking: false)

    /// The words VoiceOver reads: "Supports text, image, voice, thinking".
    public var accessibilityText: String {
        "Supports " + capabilities.map { $0.title.lowercased() }.joined(separator: ", ")
            + (imageIsTight ? ". Images are close to this device's memory limit" : "")
    }
}
