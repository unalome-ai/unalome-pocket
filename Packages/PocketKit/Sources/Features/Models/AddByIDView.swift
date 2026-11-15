import ModelCatalog
import SwiftUI
import UnalomeDesign

/// Look up a model on Hugging Face by `organisation/model`, check it, and download it.
struct AddByIDView: View {
    let library: ModelLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var repoID = ""
    @State private var isChecking = false
    @State private var result: AddByID.Result?
    @State private var errorMessage: String?
    @State private var acceptsLicense = false

    var body: some View {
        Form {
            Section {
                TextField("organisation/model", text: $repoID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(check)
                Button(isChecking ? "Checking…" : "Check", action: check)
                    .disabled(isChecking || !RepoID.isValid(repoID.trimmingCharacters(in: .whitespaces)))
            } footer: {
                Text("Only public MLX models work, for example from mlx-community. Added models are not checked by Unalome.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(UnalomeColor.error)
                }
            }

            if let result {
                Section(result.entry.displayName) {
                    LabeledContent("Download", value: ByteFormat.file(result.entry.downloadSizeBytes))
                    LabeledContent("Memory (estimate)", value: ByteFormat.memory(result.entry.minimumMemoryBytes))
                    LabeledContent("Licence", value: result.entry.license.name)
                    if let warning = result.warning {
                        Text(warning)
                            .foregroundStyle(UnalomeColor.warning)
                    }
                    Toggle("I accept the model's licence", isOn: $acceptsLicense)
                    Button("Download \(ByteFormat.file(result.entry.downloadSizeBytes))") {
                        library.add(result.entry)
                        library.download(result.entry)
                        dismiss()
                    }
                    .disabled(!acceptsLicense)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(UnalomeColor.background)
        .navigationTitle("Add by ID")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func check() {
        let id = repoID.trimmingCharacters(in: .whitespaces)
        guard RepoID.isValid(id), !isChecking else { return }
        isChecking = true
        result = nil
        errorMessage = nil
        acceptsLicense = false
        Task {
            do {
                result = try await library.inspect(repoID: id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isChecking = false
        }
    }
}
