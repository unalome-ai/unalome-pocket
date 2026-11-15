import ModelCatalog
import SwiftUI
import UnalomeDesign

/// Shows a model's licence and asks the user to accept it before the download starts.
struct LicenseSheet: View {
    let entry: CatalogEntry
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Licence")
                        .unalomeText(.eyebrow)
                        .foregroundStyle(UnalomeColor.textTertiary)
                    Text(entry.displayName)
                        .unalomeText(.title)
                    Text("This model is published under the \(entry.license.name). Read it before you download; by downloading you accept its terms.")
                        .unalomeText(.body)
                        .foregroundStyle(UnalomeColor.textSecondary)
                    if let url = entry.license.url {
                        Link("Read the licence", destination: url)
                            .unalomeText(.headline)
                    }
                    if !entry.isVerified {
                        Text("Unalome has not checked this model. It may not load or may answer badly.")
                            .unalomeText(.footnote)
                            .foregroundStyle(UnalomeColor.warning)
                    }
                    Button("Accept and download \(ByteFormat.file(entry.downloadSizeBytes))", action: onAccept)
                        .buttonStyle(.unalomePrimary)
                        .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(UnalomeColor.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
