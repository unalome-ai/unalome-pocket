import ChatCore
import ModelCatalog
import SwiftUI
import UnalomeDesign

/// Installed models, the catalog grouped by how well each model suits this device,
/// add by ID, storage used, delete.
struct ModelsView: View {
    let services: AppServices

    @State private var licenseRequest: CatalogEntry?
    @State private var isAddingByID = false
    @State private var errorMessage: String?

    private var library: ModelLibrary { services.library }

    var body: some View {
        let recommendation = library.recommendation(appleModel: services.appleModelAvailability())
        List {
            Section {
                StorageRow(usedBytes: library.storageUsedBytes, freeBytes: library.deviceProfile().freeDiskBytes)
            }

            if !library.installed.isEmpty {
                Section("On this device") {
                    ForEach(library.installed) { model in
                        InstalledRow(
                            model: model,
                            isInUse: services.host.choice == .localModel(repoID: model.repoID),
                            canRun: services.canRunLocalModels
                        ) {
                            Task { await services.select(.localModel(repoID: model.repoID)) }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(model.repoID) }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(model.repoID) }
                        }
                    }
                }
            }

            Section("Built in") {
                AppleModelRow(
                    availability: recommendation.appleModel,
                    isInUse: services.host.choice == .appleOnDevice
                ) {
                    Task { await services.select(.appleOnDevice) }
                }
            }

            ForEach(CatalogGroup.allCases, id: \.self) { group in
                let entries = entries(in: group, recommendation: recommendation)
                if !entries.isEmpty {
                    Section(group.title) {
                        ForEach(entries) { entry in
                            catalogRow(entry, label: recommendation.label(for: entry.id))
                        }
                    }
                }
            }

            if !pendingAddedEntries.isEmpty {
                Section("Added by you") {
                    ForEach(pendingAddedEntries) { entry in
                        catalogRow(entry, label: .runsWell)
                    }
                }
            }

            Section {
                ThisDeviceSection(library: library)
            } header: {
                Text("This device")
            } footer: {
                Text("Measured on this device after each reply. Memory budget is read once at launch, before any model loads.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(UnalomeColor.background)
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add by ID", systemImage: "plus") { isAddingByID = true }
            }
        }
        .sheet(item: $licenseRequest) { entry in
            LicenseSheet(entry: entry) {
                library.download(entry)
                licenseRequest = nil
            }
        }
        .sheet(isPresented: $isAddingByID) {
            NavigationStack {
                AddByIDView(library: library)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { library.reloadInstalled() }
    }

    private func catalogRow(_ entry: CatalogEntry, label: ModelLabel) -> some View {
        CatalogRow(
            entry: entry,
            label: label,
            download: library.downloads[entry.id],
            onDownload: { licenseRequest = entry },
            onResume: { library.download(entry) },
            onPause: { library.pause(entry.id) },
            onDiscard: { library.discard(entry.id) }
        )
    }

    private var pendingAddedEntries: [CatalogEntry] {
        library.addedEntries.filter { library.installedModel(id: $0.id) == nil }
    }

    /// Catalog models not yet installed, in the group their label puts them, best quality first.
    private func entries(in group: CatalogGroup, recommendation: Recommendation) -> [CatalogEntry] {
        library.catalog.models
            .filter { library.installedModel(id: $0.id) == nil }
            .filter { CatalogGroup(recommendation.label(for: $0.id)) == group }
            .sorted { $0.qualityRank > $1.qualityRank }
    }

    private func delete(_ repoID: String) {
        Task {
            do {
                try await services.deleteModel(repoID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Sections of the catalog, recommended first.
private enum CatalogGroup: CaseIterable {
    case recommended, runsWell, tight, tooLarge

    init(_ label: ModelLabel) {
        switch label {
        case .recommended: self = .recommended
        case .runsWell: self = .runsWell
        case .tight: self = .tight
        case .tooLarge: self = .tooLarge
        }
    }

    var title: String {
        switch self {
        case .recommended: "Recommended for this device"
        case .runsWell: "Runs well"
        case .tight: "Tight fit"
        case .tooLarge: "Too large for this device"
        }
    }
}

// MARK: - Rows

private struct StorageRow: View {
    let usedBytes: Int64
    let freeBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Storage")
                .unalomeText(.eyebrow)
                .foregroundStyle(UnalomeColor.textTertiary)
            Text("Models use \(ByteFormat.file(usedBytes))")
                .unalomeText(.headline)
            if let freeBytes {
                Text("\(ByteFormat.file(freeBytes)) free on this device")
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InstalledRow: View {
    let model: InstalledModel
    let isInUse: Bool
    let canRun: Bool
    let onUse: () -> Void

    var body: some View {
        Button(action: onUse) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .unalomeText(.headline)
                            .foregroundStyle(UnalomeColor.textPrimary)
                        if !model.isVerified {
                            Tag(text: "Unverified", color: UnalomeColor.warning)
                        }
                    }
                    Text(details)
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeColor.textSecondary)
                }
                Spacer()
                if isInUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UnalomeColor.emerald)
                        .accessibilityLabel("In use")
                }
            }
        }
        .disabled(!canRun || isInUse)
    }

    private var details: String {
        var parts = [ByteFormat.file(model.sizeBytes), model.licenseName]
        if let speed = model.measuredTokensPerSecond {
            parts.append("\(Int(speed.rounded())) tok/s measured")
        }
        if !canRun {
            parts.append("runs on a real device only")
        }
        return parts.joined(separator: " · ")
    }
}

private struct AppleModelRow: View {
    let availability: AppleModelAvailability
    let isInUse: Bool
    let onUse: () -> Void

    var body: some View {
        Button(action: onUse) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple on-device model")
                        .unalomeText(.headline)
                        .foregroundStyle(UnalomeColor.textPrimary)
                    Text(availability.isAvailable ? "No download needed. Text only." : availability.explanation)
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeColor.textSecondary)
                }
                Spacer()
                if isInUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UnalomeColor.emerald)
                        .accessibilityLabel("In use")
                }
            }
        }
        .disabled(!availability.isAvailable || isInUse)
    }
}

private struct CatalogRow: View {
    let entry: CatalogEntry
    let label: ModelLabel
    let download: ModelLibrary.DownloadState?
    let onDownload: () -> Void
    let onResume: () -> Void
    let onPause: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.displayName)
                    .unalomeText(.headline)
                if label == .recommended {
                    Tag(text: "Recommended", color: UnalomeColor.emerald)
                }
                if !entry.isVerified {
                    Tag(text: "Unverified", color: UnalomeColor.warning)
                }
            }
            Text(entry.goodFor)
                .unalomeText(.callout)
                .foregroundStyle(UnalomeColor.textSecondary)
            Text(details)
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
            if case .tooLarge(let reason) = label {
                Text(reason)
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.warning)
            }
            controls
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        let memory = ByteFormat.memory(entry.minimumMemoryBytes)
        return "\(ByteFormat.file(entry.downloadSizeBytes)) · needs about \(memory) memory"
            + (entry.minimumMemoryIsEstimate ? " (estimate)" : "")
            + " · \(entry.license.name)"
    }

    @ViewBuilder
    private var controls: some View {
        switch download {
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress?.fraction ?? 0)
                    .tint(UnalomeColor.emerald)
                Text(progressText(progress))
                    .unalomeText(.footnote)
                    .monospacedDigit()
                Button("Pause", systemImage: "pause.circle", action: onPause)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        case .paused(let progress):
            HStack {
                Text("Paused" + (progress.map { " at \(Int($0.fraction * 100))%" } ?? ""))
                    .unalomeText(.footnote)
                Spacer()
                Button("Resume", action: onResume)
                Button("Delete", role: .destructive, action: onDiscard)
            }
            .buttonStyle(.borderless)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.error)
                Button("Try again", action: onResume)
                    .buttonStyle(.borderless)
            }
        case nil:
            if label.isUsable {
                Button("Download \(ByteFormat.file(entry.downloadSizeBytes))", action: onDownload)
                    .buttonStyle(.unalomePrimary)
            }
        }
    }

    private func progressText(_ progress: DownloadProgress?) -> String {
        guard let progress else { return "Starting…" }
        return "\(Int(progress.fraction * 100))%"
    }
}

/// The figures the recommender uses, so the user can read them back to us.
private struct ThisDeviceSection: View {
    let library: ModelLibrary

    var body: some View {
        let launch = library.deviceProvider.atLaunch
        Group {
            row("Device", launch.machineIdentifier)
            row("Memory", ByteFormat.memory(launch.physicalMemoryBytes))
            row(
                "Budget at launch",
                ByteFormat.memory(launch.memoryBudgetBytes)
                    + (launch.availableMemoryBytes == nil ? " (60% of memory)" : ""))
            ForEach(library.installed) { model in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .unalomeText(.callout)
                    Text(measurements(model))
                        .unalomeText(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(UnalomeColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(UnalomeColor.textSecondary)
        }
        .unalomeText(.callout)
    }

    private func measurements(_ model: InstalledModel) -> String {
        var parts: [String] = []
        if let peak = model.measuredPeakMemoryBytes {
            parts.append("peak \(ByteFormat.memory(peak))")
        } else {
            parts.append("estimate \(ByteFormat.memory(model.minimumMemoryBytes))")
        }
        if let footprint = model.measuredFootprintBytes {
            parts.append("app \(ByteFormat.memory(footprint))")
        }
        if let speed = model.measuredTokensPerSecond {
            parts.append(String(format: "%.1f tok/s", speed))
        }
        if model.measuredPeakMemoryBytes == nil && model.measuredTokensPerSecond == nil {
            parts.append("not measured yet")
        }
        return parts.joined(separator: " · ")
    }
}

/// A small coloured label, e.g. "Recommended".
struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .unalomeText(.eyebrow)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1) }
    }
}
