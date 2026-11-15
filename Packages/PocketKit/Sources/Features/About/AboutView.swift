import ModelCatalog
import SwiftUI
import UnalomeDesign

/// App name and version, the privacy statement, links, and every licence the app ships under.
struct AboutView: View {
    let services: AppServices

    @State private var isRevealed = false

    /// Where "Report a problem" writes to. `nil` hides the row until an address exists.
    static let reportProblemAddress: String? = nil

    static let websiteURL = URL(string: "https://unalome.ai")

    static let privacyStatement = """
        Unalome Pocket runs language models entirely on this device. There is no account, no \
        analytics and no telemetry: your messages, images, voice and chats are processed and \
        stored only here. The only time the app uses the network is to download a model you \
        choose, from huggingface.co.
        """

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .frame(maxWidth: .infinity)
            }

            Section("Privacy") {
                Text(Self.privacyStatement)
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if let url = Self.websiteURL {
                    Link(destination: url) {
                        Label("unalome.ai", systemImage: "globe")
                    }
                }
                if let address = Self.reportProblemAddress, let url = URL(string: "mailto:\(address)") {
                    Link(destination: url) {
                        Label("Report a problem", systemImage: "envelope")
                    }
                }
            }

            Section {
                ForEach(modelLicenses, id: \.name) { model in
                    LicenseRow(name: model.name, licence: model.licence, url: model.url)
                }
            } header: {
                Text("Model licences")
            } footer: {
                Text("Each model is downloaded only after you accept its licence.")
            }

            Section("Open-source software") {
                ForEach(OpenSourceComponent.all) { component in
                    LicenseRow(
                        name: component.version.isEmpty ? component.name : "\(component.name) \(component.version)",
                        licence: component.licence,
                        url: component.url)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GlowBackdrop())
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { isRevealed = true }
    }

    private var header: some View {
        VStack(spacing: 14) {
            UnalomeMark(height: 64)
                .revealed(isRevealed)
            VStack(spacing: 4) {
                Text("Unalome Pocket")
                    .unalomeText(.title)
                    .foregroundStyle(UnalomeColor.textPrimary)
                Text(Self.versionText)
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textTertiary)
            }
            .revealed(isRevealed, delay: 0.15)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 16)
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    /// Catalog models plus anything installed from outside the catalog.
    private var modelLicenses: [(name: String, licence: String, url: URL?)] {
        let library = services.library
        var rows = (library.catalog.models + library.addedEntries).map {
            (name: $0.displayName, licence: $0.license.name, url: $0.license.url)
        }
        for model in library.installed where !rows.contains(where: { $0.name == model.displayName }) {
            rows.append((name: model.displayName, licence: model.licenseName, url: model.licenseURL))
        }
        return rows
    }
}

private struct LicenseRow: View {
    let name: String
    let licence: String
    let url: URL?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .unalomeText(.body)
                .foregroundStyle(UnalomeColor.textPrimary)
            Text(licence)
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textSecondary)
        }
        if let url {
            Link(destination: url) {
                HStack {
                    content
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                        .foregroundStyle(UnalomeColor.textTertiary)
                }
            }
            .accessibilityHint("Opens the licence")
        } else {
            content
        }
    }
}

/// Every resolved package dependency (Package.resolved) and bundled asset, with its licence
/// as stated in its LICENSE file.
struct OpenSourceComponent: Identifiable, Sendable {
    let name: String
    let version: String
    let licence: String
    let url: URL?

    var id: String { name }

    init(_ name: String, _ version: String, _ licence: String, _ url: String) {
        self.name = name
        self.version = version
        self.licence = licence
        self.url = URL(string: url)
    }

    static let all: [OpenSourceComponent] = [
        .init("EventSource", "1.6.0", "MIT", "https://github.com/mattt/EventSource"),
        .init("Inter (font)", "", "SIL Open Font License 1.1", "https://github.com/rsms/inter"),
        .init("MLX Swift", "0.32.3", "MIT", "https://github.com/ml-explore/mlx-swift"),
        .init("MLX Swift LM", "3.32.3", "MIT", "https://github.com/ml-explore/mlx-swift-lm"),
        .init("swift-asn1", "1.7.4", "Apache 2.0", "https://github.com/apple/swift-asn1"),
        .init("swift-cmark", "0.9.0", "BSD 2-Clause", "https://github.com/swiftlang/swift-cmark"),
        .init("swift-collections", "1.7.6", "Apache 2.0", "https://github.com/apple/swift-collections"),
        .init("swift-crypto", "4.5.2", "Apache 2.0", "https://github.com/apple/swift-crypto"),
        .init("swift-huggingface", "1.0.0", "Apache 2.0", "https://github.com/huggingface/swift-huggingface"),
        .init("swift-jinja", "3.1.0", "Apache 2.0", "https://github.com/huggingface/swift-jinja"),
        .init("swift-markdown", "0.9.0", "Apache 2.0", "https://github.com/swiftlang/swift-markdown"),
        .init("swift-numerics", "1.1.1", "Apache 2.0", "https://github.com/apple/swift-numerics"),
        .init("swift-syntax", "603.0.2", "Apache 2.0", "https://github.com/swiftlang/swift-syntax"),
        .init("swift-transformers", "1.4.0", "Apache 2.0", "https://github.com/huggingface/swift-transformers"),
        .init("yyjson", "0.13.0", "MIT", "https://github.com/ibireme/yyjson"),
    ]
}
