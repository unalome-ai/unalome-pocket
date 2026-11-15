import ChatCore
import ModelCatalog
import SwiftUI
import UnalomeDesign
#if canImport(UIKit)
import UIKit
#endif

/// First run, three steps: welcome → pick a model → download (or start with Apple's model).
///
/// The unalome carries the motion: it draws itself once on the welcome step, and on the
/// download step the same line is the progress indicator, complete when the model has arrived.
struct OnboardingView: View {
    let services: AppServices
    let onFinish: () -> Void

    private enum Step: Int {
        case welcome, pick, download
    }

    private enum Pick: Hashable {
        case catalog(String)
        case builtIn
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var isMovingForward = true
    @State private var pick: Pick?
    @State private var showsOtherModels = false
    @State private var welcomeDrawing = 0.0
    @State private var isWelcomeRevealed = false

    private static let introDuration = 2.4
    private static let contentWidth: CGFloat = 520

    private var library: ModelLibrary { services.library }

    var body: some View {
        let recommendation = library.recommendation(appleModel: services.appleModelAvailability())
        VStack(spacing: 0) {
            header
            ScrollView {
                page(recommendation)
                    .frame(maxWidth: Self.contentWidth, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                    .id(step)
                    .transition(pageTransition)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            actions(recommendation)
                .frame(maxWidth: Self.contentWidth)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
        }
        .background { GlowBackdrop() }
        .onAppear {
            if pick == nil {
                pick = recommendation.recommendedID.map(Pick.catalog)
                    ?? (recommendation.appleModel.isAvailable ? .builtIn : nil)
            }
            playIntro()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                if step == .welcome {
                    UnalomeMark(height: 26)
                    Text("Unalome Pocket")
                        .unalomeText(.headline)
                        .foregroundStyle(UnalomeColor.textPrimary)
                } else {
                    Button {
                        go(to: step == .download ? .pick : .welcome)
                    } label: {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UnalomeColor.textPrimary)
                    .liquidGlass(in: Circle(), interactive: true)
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
            .frame(height: 36)

            ProgressLine(fraction: Double(step.rawValue + 1) / 3)
                .animation(.smooth(duration: 0.45), value: step)
                .accessibilityElement()
                .accessibilityLabel("Step \(step.rawValue + 1) of 3")
        }
        .frame(maxWidth: Self.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ recommendation: Recommendation) -> some View {
        switch step {
        case .welcome: welcomePage
        case .pick: pickPage(recommendation)
        case .download: downloadPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            UnalomeDrawing(progress: welcomeDrawing, tipDelay: reduceMotion ? 0 : Self.introDuration - 0.15)
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

            headline("Your AI.", "In your pocket.")
                .revealed(isWelcomeRevealed, delay: 0.9)

            Text("Open models that run entirely on this device. No account, no cloud, no telemetry. Your chats never leave it.")
                .unalomeText(.body)
                .foregroundStyle(UnalomeColor.textSecondary)
                .revealed(isWelcomeRevealed, delay: 1.15)
        }
    }

    private func pickPage(_ recommendation: Recommendation) -> some View {
        let usable = library.catalog.models
            .filter { recommendation.label(for: $0.id).isUsable }
            .sorted { $0.qualityRank > $1.qualityRank }
        let recommended = usable.first { $0.id == recommendation.recommendedID }
        let others = usable.filter { $0.id != recommendation.recommendedID }

        return VStack(alignment: .leading, spacing: 18) {
            headline("Chosen for", deviceNoun)
            Text("Matched to this device's memory and free storage. You can add or switch models later.")
                .unalomeText(.callout)
                .foregroundStyle(UnalomeColor.textSecondary)

            if let recommended {
                RecommendedCard(entry: recommended, isSelected: pick == .catalog(recommended.id)) {
                    pick = .catalog(recommended.id)
                }
            }

            if recommendation.appleModel.isAvailable {
                PickRow(
                    title: "Apple on-device model",
                    detail: "Built in. No download, text only.",
                    isSelected: pick == .builtIn
                ) { pick = .builtIn }
            }

            if !others.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.35)) { showsOtherModels.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showsOtherModels ? "Hide other models" : "Show \(others.count) other models that fit")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showsOtherModels ? 180 : 0))
                    }
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textSecondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsOtherModels {
                    VStack(spacing: 8) {
                        ForEach(others) { entry in
                            PickRow(
                                title: entry.displayName,
                                detail: "\(ByteFormat.file(entry.downloadSizeBytes)). \(entry.goodFor)",
                                isSelected: pick == .catalog(entry.id)
                            ) { pick = .catalog(entry.id) }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if usable.isEmpty && !recommendation.appleModel.isAvailable {
                Text("No model in the catalog fits this device's free memory or storage.")
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.warning)
            }
        }
    }

    private var downloadPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            UnalomeDrawing(progress: downloadDrawing)
                .animation(.smooth(duration: 0.4), value: downloadDrawing)
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

            switch pick {
            case .catalog(let id):
                if let entry = library.entry(id: id) {
                    downloadDetails(entry)
                }
            case .builtIn, nil:
                headline("Ready", "right now.")
                Text("Apple's model is already on this device.")
                    .unalomeText(.body)
                    .foregroundStyle(UnalomeColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func downloadDetails(_ entry: CatalogEntry) -> some View {
        if library.installedModel(id: entry.id) != nil {
            headline(entry.displayName, "is ready.")
            Text("Downloaded to this device. It works without a connection from now on.")
                .unalomeText(.body)
                .foregroundStyle(UnalomeColor.textSecondary)
        } else {
            switch library.downloads[entry.id] {
            case .downloading(let progress):
                headline(entry.displayName, "\(Int((progress?.fraction ?? 0) * 100))%")
                    .monospacedDigit()
                Text("Downloading \(ByteFormat.file(entry.downloadSizeBytes)). Keep the app open until it finishes.")
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.textSecondary)
            case .paused:
                headline(entry.displayName, "paused.")
                Text("What has arrived so far is kept. Resume to carry on from there.")
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.textSecondary)
            case .failed(let message):
                headline(entry.displayName, "stopped.")
                Text(message)
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.error)
            case nil:
                headline(entry.displayName, ByteFormat.file(entry.downloadSizeBytes) + ".")
                Text("Published under the \(entry.license.name). By downloading you accept its terms.")
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.textSecondary)
                if let url = entry.license.url {
                    Link("Read the licence", destination: url)
                        .unalomeText(.callout)
                }
            }
        }
    }

    /// How much of the unalome is drawn on the download step.
    private var downloadDrawing: Double {
        switch pick {
        case .builtIn, nil:
            return 1
        case .catalog(let id):
            if library.installedModel(id: id) != nil { return 1 }
            switch library.downloads[id] {
            case .downloading(let progress), .paused(let progress): return progress?.fraction ?? 0
            case .failed, nil: return 0
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ recommendation: Recommendation) -> some View {
        VStack(spacing: 12) {
            switch step {
            case .welcome:
                primaryButton("Continue") { go(to: .pick) }
                    .revealed(isWelcomeRevealed, delay: 1.4)
                Text("Free and open source, from [unalome.ai](https://unalome.ai)")
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textTertiary)
                    .revealed(isWelcomeRevealed, delay: 1.6)
            case .pick:
                primaryButton("Continue") { go(to: .download) }
                    .disabled(pick == nil)
            case .download:
                downloadActions(recommendation)
            }
        }
    }

    @ViewBuilder
    private func downloadActions(_ recommendation: Recommendation) -> some View {
        switch pick {
        case .catalog(let id):
            if let entry = library.entry(id: id) {
                if library.installedModel(id: id) != nil {
                    primaryButton("Start chatting") { finish(with: .localModel(repoID: id)) }
                        .disabled(!services.canRunLocalModels)
                } else {
                    switch library.downloads[id] {
                    case .downloading:
                        secondaryButton("Pause download") { library.pause(id) }
                    case .paused, .failed:
                        primaryButton("Resume download") { library.download(entry) }
                    case nil:
                        primaryButton("Accept and download \(ByteFormat.file(entry.downloadSizeBytes))") {
                            library.download(entry)
                        }
                    }
                }
            }
            if recommendation.appleModel.isAvailable {
                secondaryButton("Start now with the built-in model") { finish(with: .appleOnDevice) }
            }
        case .builtIn, nil:
            if recommendation.appleModel.isAvailable {
                primaryButton("Start chatting") { finish(with: .appleOnDevice) }
            }
        }
        if !services.canRunLocalModels {
            Text("Downloaded models run on a real device. In the Simulator, chats use the scripted demo.")
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
                .multilineTextAlignment(.center)
            secondaryButton("Continue with the demo") { finish(with: .scripted) }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        }
        .buttonStyle(.unalomePrimary)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .unalomeText(.callout)
                .foregroundStyle(UnalomeColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func headline(_ first: String, _ second: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(first)
                .foregroundStyle(UnalomeColor.textPrimary)
            GradientText(LocalizedStringKey(second))
        }
        .unalomeText(.display)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var deviceNoun: String {
        #if os(macOS)
        "this Mac."
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad." : "this iPhone."
        #endif
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isMovingForward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(to newStep: Step) {
        isMovingForward = newStep.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.45)) {
            step = newStep
        }
    }

    /// The one orchestrated moment: the unalome draws itself, then the words arrive.
    private func playIntro() {
        guard !isWelcomeRevealed else { return }
        if reduceMotion {
            welcomeDrawing = 1
        } else {
            withAnimation(.easeInOut(duration: Self.introDuration)) {
                welcomeDrawing = 1
            }
        }
        isWelcomeRevealed = true
    }

    private func finish(with choice: EngineChoice) {
        Task {
            await services.select(choice)
            onFinish()
        }
    }
}

/// The recommended model, given the room a decision deserves.
private struct RecommendedCard: View {
    let entry: CatalogEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recommended")
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeGradient.brand)
                    Spacer()
                    SelectionMark(isSelected: isSelected)
                }
                Text(entry.displayName)
                    .unalomeText(.title)
                    .foregroundStyle(UnalomeColor.textPrimary)
                Text(entry.goodFor)
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.textSecondary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 24) {
                    fact("Download", ByteFormat.file(entry.downloadSizeBytes))
                    fact("Licence", entry.license.name)
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UnalomeColor.glassFill, in: shape)
            .overlay {
                if isSelected {
                    shape.strokeBorder(UnalomeGradient.brand, lineWidth: 1.5)
                } else {
                    shape.strokeBorder(UnalomeColor.glassBorder, lineWidth: 1)
                }
            }
            .shadow(color: UnalomeColor.emerald.opacity(isSelected ? 0.22 : 0), radius: 30)
            .animation(.smooth(duration: 0.25), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
            Text(value)
                .unalomeText(.headline)
                .foregroundStyle(UnalomeColor.textPrimary)
        }
    }
}

private struct PickRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UnalomeRadius.card, style: .continuous)
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .unalomeText(.headline)
                        .foregroundStyle(UnalomeColor.textPrimary)
                    Text(detail)
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeColor.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                SelectionMark(isSelected: isSelected)
            }
            .padding(14)
            .background(UnalomeColor.glassFill, in: shape)
            .overlay {
                shape.strokeBorder(
                    isSelected ? UnalomeColor.emerald.opacity(0.7) : UnalomeColor.glassBorder, lineWidth: 1)
            }
            .animation(.smooth(duration: 0.25), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? UnalomeColor.emerald : UnalomeColor.textTertiary)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
