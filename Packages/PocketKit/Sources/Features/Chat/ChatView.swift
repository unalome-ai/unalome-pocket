import ChatCore
import PhotosUI
import SwiftData
import SwiftUI
import UnalomeDesign
#if os(iOS)
import UIKit
#endif

/// One conversation: the message list, the status pill and the composer.
public struct ChatView: View {
    @State private var model: ChatViewModel
    @State private var voice = VoiceInput()
    @State private var isShowingPersonas = false
    @Environment(\.scenePhase) private var scenePhase
    private let services: AppServices

    private let startAction: ChatStartAction?
    private let onStartActionHandled: () -> Void

    /// - Parameter startAction: What to do once on appearing, for chats opened by Siri,
    ///   Shortcuts or a widget.
    public init(
        conversation: Conversation, store: ConversationStore, services: AppServices,
        startAction: ChatStartAction? = nil, onStartActionHandled: @escaping () -> Void = {}
    ) {
        let model = ChatViewModel(conversation: conversation, store: store, host: services.host)
        model.onReplyFinished = { choice, metrics in services.record(metrics, for: choice) }
        model.onReplySaved = { services.widgetSnapshots?.publish(from: store) }
        _model = State(initialValue: model)
        self.services = services
        self.startAction = startAction
        self.onStartActionHandled = onStartActionHandled
    }

    private func runStartAction() {
        guard let startAction else { return }
        onStartActionHandled()
        switch startAction {
        case .listen:
            voice.onTranscript = { [model] text in model.draft = text.trimmingCharacters(in: .whitespaces) }
            voice.toggle()
        case .ask(let question):
            model.draft = question
            if services.canAnswerRoutedQuestions {
                model.send()
            }
        }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(model.messages) { message in
                    if message.id == model.contextBoundaryMessageID {
                        ContextLimitNote()
                    }
                    MessageRow(message: message, model: model)
                }
                if !model.messages.isEmpty {
                    AINotice()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .readableWidth()
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.messages.isEmpty {
                EmptyChatView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerArea(model: model, voice: voice)
                .readableWidth()
        }
        .background(UnalomeColor.background)
        .navigationTitle(model.conversation.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelPill(services: services, model: model) { isShowingPersonas = true }
            }
        }
        .sheet(isPresented: $isShowingPersonas) {
            NavigationStack {
                PersonasView(services: services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingPersonas = false }
                        }
                    }
            }
        }
        .focusedSceneValue(\.chatModel, model)
        .task { runStartAction() }
        // Leaving the conversation stops the reply and keeps what was written so far.
        .onDisappear {
            model.stop()
            voice.cancel()
            model.discardDraftAttachments()
        }
        // iOS does not allow GPU work or recording in the background, so stop before suspension.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.stop()
                voice.cancel()
            }
        }
    }
}

/// Something a chat does once when it opens from outside the app.
public enum ChatStartAction: Equatable, Sendable {
    /// Start dictation.
    case listen
    /// Put the question in the composer and send it if a model can answer.
    case ask(String)
}

// MARK: - Messages

private struct MessageRow: View {
    let message: Message
    let model: ChatViewModel

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantReply
        case .system: EmptyView()
        }
    }

    private var isStreaming: Bool {
        model.isGenerating && message.id == model.messages.last?.id
    }

    private var userBubble: some View {
        let shape = RoundedRectangle(cornerRadius: UnalomeRadius.card, style: .continuous)
        return HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachmentNames.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachmentNames, id: \.self) { name in
                            if let url = model.url(forAttachment: name) {
                                AttachmentThumbnail(url: url, side: 96)
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    MarkdownText(message.text)
                        .foregroundStyle(UnalomeColor.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(UnalomeColor.glassFill, in: shape)
                        .overlay { shape.strokeBorder(UnalomeGradient.brand, lineWidth: 1) }
                }
            }
        }
        .contextMenu {
            CopyButton(text: message.text)
            if message.id == model.lastUserMessage?.id, !model.isGenerating {
                Button("Edit", systemImage: "pencil") { model.beginEditing(message) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "You: \(message.text)"
                + (message.attachmentNames.isEmpty ? "" : ", \(message.attachmentNames.count) image(s) attached"))
    }

    private var assistantReply: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.reasoning.isEmpty {
                ReasoningDisclosure(
                    reasoning: message.reasoning,
                    seconds: message.reasoningSeconds,
                    startedAt: isStreaming ? model.reasoningStartedAt : nil)
            }
            if message.text.isEmpty && isStreaming {
                if message.reasoning.isEmpty {
                    PulsingDot()
                        .padding(.vertical, 6)
                        .accessibilityLabel("Writing")
                }
            } else {
                MarkdownView(text: message.text)
                    .equatable()
                    .foregroundStyle(UnalomeColor.textPrimary)
                    .tint(UnalomeColor.emerald)
                    .textSelection(.enabled)
            }
            if !isStreaming {
                if let stopNote {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { stopLine(stopNote) }
                        VStack(alignment: .leading, spacing: 4) { stopLine(stopNote) }
                    }
                }
                HStack(spacing: 4) {
                    CopyButton(text: message.text)
                        .frame(minWidth: 44, minHeight: 44)
                    if isLast, model.canRegenerate {
                        Button("Regenerate", systemImage: "arrow.clockwise", action: model.regenerate)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    ReportButton(message: message, model: model)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(UnalomeColor.textTertiary)
                .padding(.leading, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            CopyButton(text: message.text)
            if isLast, model.canRegenerate {
                Button("Regenerate", systemImage: "arrow.clockwise", action: model.regenerate)
            }
            ReportButton(message: message, model: model)
        }
    }

    private var isLast: Bool { message.id == model.messages.last?.id }

    /// Why the reply ended early, if it did.
    private var stopNote: String? {
        if message.stoppedAtLengthLimit { return "Stopped at the length limit" }
        if message.wasInterrupted { return "Stopped before the end" }
        return nil
    }

    @ViewBuilder
    private func stopLine(_ note: String) -> some View {
        Text(note)
            .unalomeText(.footnote)
            .foregroundStyle(UnalomeColor.textSecondary)
        if isLast, model.canContinue {
            Button("Continue", action: model.continueReply)
                .unalomeText(.footnote)
                .buttonStyle(.borderless)
                .foregroundStyle(UnalomeColor.emerald)
                .frame(minHeight: 44)
                .accessibilityHint("Asks the model to finish this reply")
        }
    }
}

/// "Report this response": explains what happens, then opens a prefilled email. Nothing is sent
/// by the app (App Review guideline 1.2).
private struct ReportButton: View {
    let message: Message
    let model: ChatViewModel
    @State private var isConfirming = false
    @State private var couldNotOpenMail = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Report this response", systemImage: "flag") { isConfirming = true }
            .accessibilityHint("Opens an email you can review before sending")
            .confirmationDialog("Report this response?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Write email") { openMail() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ReportEmail.explanation)
            }
            .alert("No mail app", isPresented: $couldNotOpenMail) {
                Button("Copy address") { Clipboard.copy(AppLinks.supportEmail) }
                Button("OK", role: .cancel) {}
            } message: {
                Text("Set up a mail app, or write to \(AppLinks.supportEmail) and paste the response.")
            }
    }

    private func openMail() {
        let index = model.messages.firstIndex { $0.id == message.id }
        let question = index.flatMap { i in model.messages[..<i].last { $0.role == .user }?.text }
        let email = ReportEmail(
            question: question, reply: message.text, modelName: model.engineName,
            appVersion: AppVersion.display, deviceName: DeviceWording.name)
        guard let url = email.url else { return }
        openURL(url) { accepted in
            if !accepted { couldNotOpenMail = true }
        }
    }
}

/// Below the conversation: the replies come from a small on-device model and can be wrong.
private struct AINotice: View {
    var body: some View {
        Label("Replies are AI-generated and can be wrong. Check anything important.", systemImage: "sparkles")
            .unalomeText(.footnote)
            .foregroundStyle(UnalomeColor.textTertiary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

/// The model's reasoning above its answer: collapsed and dimmed, expandable.
/// "Thinking… N s" while it streams, "Thought for N s" afterwards.
private struct ReasoningDisclosure: View {
    let reasoning: String
    let seconds: Double?
    /// Set while the reasoning is still streaming.
    let startedAt: Date?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .imageScale(.small)
                    title
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the model's reasoning" : "Shows the model's reasoning")

            if isExpanded {
                Text(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                    .unalomeText(.callout)
                    .foregroundStyle(UnalomeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(UnalomeColor.glassBorder)
                            .frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        if let seconds {
            Text("Thought for \(Self.format(seconds))")
        } else if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Thinking… \(Self.format(context.date.timeIntervalSince(startedAt)))")
                    .monospacedDigit()
            }
        } else {
            Text("Thought")
        }
    }

    private static func format(_ seconds: Double) -> String {
        "\(max(Int(seconds.rounded()), 1)) s"
    }
}

/// Message text with basic inline Markdown (bold, italic, code, links).
private struct MarkdownText: View {
    private let attributed: AttributedString

    init(_ text: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributed)
            .unalomeText(.body)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CopyButton: View {
    let text: String

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(text) }
    }
}

// MARK: - Empty state

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Private by design")
                .unalomeText(.eyebrow)
                .foregroundStyle(UnalomeColor.textTertiary)
            VStack(spacing: 0) {
                Text("Nothing leaves")
                    .foregroundStyle(UnalomeColor.textPrimary)
                GradientText("\(DeviceWording.thisDevice).")
            }
            .unalomeText(.display)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Replies are written on \(DeviceWording.thisDevice), and your chats are stored only here.")
                .unalomeText(.callout)
                .foregroundStyle(UnalomeColor.textSecondary)
            Text("Replies are AI-generated and can be wrong.")
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

// MARK: - Composer

private struct ComposerArea: View {
    @Bindable var model: ChatViewModel
    let voice: VoiceInput

    var body: some View {
        VStack(spacing: 10) {
            if case .loading(let progress) = model.host.state {
                LoadingPill(engineName: model.engineName, progress: progress)
            } else {
                StatusPill(engineName: model.engineName, tokensPerSecond: model.tokensPerSecond)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.error)
                    .multilineTextAlignment(.center)
            }

            if let reason = voice.unavailableReason {
                VStack(spacing: 4) {
                    Text(reason)
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeColor.textSecondary)
                        .multilineTextAlignment(.center)
                    if voice.isPermissionDenied {
                        OpenSettingsButton()
                    }
                }
            }

            if voice.isRecording {
                HStack(spacing: 8) {
                    PulsingDot(color: UnalomeColor.error)
                    Text("Listening on \(DeviceWording.thisDevice)… tap the microphone to stop")
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }

            if model.editingMessage != nil {
                HStack {
                    Text("Editing your last message")
                        .unalomeText(.footnote)
                        .foregroundStyle(UnalomeColor.textSecondary)
                    Spacer()
                    Button("Cancel", action: model.cancelEditing)
                        .unalomeText(.footnote)
                }
                .padding(.horizontal, 8)
            }

            Composer(model: model, voice: voice)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct Composer: View {
    @Bindable var model: ChatViewModel
    let voice: VoiceInput
    @ScaledMetric(relativeTo: .body) private var scaledButtonSize: CGFloat = 36
    /// Grows with the text size, but not so far that the message field has no room left.
    private var buttonSize: CGFloat { min(scaledButtonSize, 48) }
    @State private var isDropTargeted = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isShowingCamera = false
    @State private var isShowingPhotos = false
    @State private var isShowingFiles = false
    /// The cursor or selection in the message field, so Shift-Return inserts the newline there.
    @State private var selection: TextSelection?

    /// Small models handle a few images per message at most.
    static let maxImages = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.draftAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.draftAttachments, id: \.self) { name in
                            if let url = model.url(forAttachment: name) {
                                AttachmentThumbnail(url: url, side: 64)
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            model.removeDraftAttachment(name)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(UnalomeColor.textPrimary, UnalomeColor.background.opacity(0.8))
                                                .padding(3)
                                        }
                                        .accessibilityLabel("Remove image")
                                    }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .scrollIndicators(.hidden)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if model.supportsImages {
                    attachMenu
                }

                TextField("Message", text: $model.draft, selection: $selection, axis: .vertical)
                    .unalomeText(.body)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .onSubmit(send)
                    // Hardware keyboards: Return sends, Shift-Return starts a new line, Esc stops.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            insertNewline()
                        } else {
                            send()
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard model.isGenerating else { return .ignored }
                        model.stop()
                        return .handled
                    }

                if !model.isGenerating {
                    micButton
                }

                if model.isGenerating {
                    Button(action: model.stop) {
                        Image(systemName: "stop.fill")
                            .frame(width: buttonSize, height: buttonSize)
                            .background(UnalomeColor.textPrimary, in: Circle())
                            .foregroundStyle(UnalomeColor.background)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .fontWeight(.bold)
                            .frame(width: buttonSize, height: buttonSize)
                            .background(UnalomeGradient.brand, in: Circle())
                            .foregroundStyle(UnalomeColor.background)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!model.canSend)
                    .opacity(model.canSend ? 1 : 0.4)
                    .accessibilityLabel(model.editingMessage == nil ? "Send" : "Send edited message")
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, model.supportsImages ? 8 : 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .liquidGlass(in: RoundedRectangle(cornerRadius: UnalomeRadius.card, style: .continuous), interactive: true)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: UnalomeRadius.card, style: .continuous)
                    .strokeBorder(UnalomeColor.emerald, lineWidth: 2)
            }
        }
        // Drag an image onto the composer (iPad, Mac) when the model reads images.
        .dropDestination(for: Data.self) { items, _ in
            guard model.supportsImages, !model.isGenerating else { return false }
            for data in items.prefix(remainingImages) { model.attachImage(data) }
            return !items.isEmpty
        } isTargeted: { isDropTargeted = model.supportsImages && $0 }
        #if os(macOS)
        .fileImporter(isPresented: $isShowingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(remainingImages) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { model.attachImage(data) }
            }
        }
        #endif
        .photosPicker(
            isPresented: $isShowingPhotos, selection: $pickedPhotos,
            maxSelectionCount: max(remainingImages, 1), matching: .images, photoLibrary: .shared())
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.attachImage(data)
                    }
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingCamera) {
            CameraPicker { data in model.attachImage(data) }
                .ignoresSafeArea()
        }
        #endif
    }

    private var remainingImages: Int {
        max(Self.maxImages - model.draftAttachments.count, 0)
    }

    private var attachMenu: some View {
        Menu {
            // A PhotosPicker inside a Menu does not present on iOS, so the menu opens it instead.
            Button("Photo library", systemImage: "photo.on.rectangle") { isShowingPhotos = true }
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button("Take photo", systemImage: "camera") { isShowingCamera = true }
            }
            #else
            Button("Choose file…", systemImage: "folder") { isShowingFiles = true }
            #endif
            Button("Paste image", systemImage: "doc.on.clipboard") {
                if let data = Clipboard.imageData() { model.attachImage(data) }
            }
            .disabled(!Clipboard.hasImage)
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
                .frame(width: buttonSize, height: buttonSize)
                .foregroundStyle(UnalomeColor.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .disabled(model.isGenerating || remainingImages == 0)
        .accessibilityLabel("Attach an image")
    }

    private var micButton: some View {
        Button {
            if voice.state == .idle {
                let prefix = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                voice.onTranscript = { [model] text in
                    let spoken = text.trimmingCharacters(in: .whitespaces)
                    model.draft = prefix.isEmpty ? spoken : prefix + " " + spoken
                }
            }
            voice.toggle()
        } label: {
            Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                .frame(width: buttonSize, height: buttonSize)
                .foregroundStyle(voice.isRecording ? UnalomeColor.background : UnalomeColor.textSecondary)
                .background(voice.isRecording ? UnalomeColor.error : .clear, in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(voice.state == .preparing)
        .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate on \(DeviceWording.thisDevice)")
    }

    /// Replaces the selection (or inserts at the cursor) with a newline; at the end without one.
    private func insertNewline() {
        var draft = model.draft
        var range = draft.endIndex..<draft.endIndex
        if case .selection(let selected) = selection?.indices,
           selected.lowerBound >= draft.startIndex, selected.upperBound <= draft.endIndex {
            range = selected
        }
        let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
        draft.replaceSubrange(range, with: "\n")
        model.draft = draft
        selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
    }

    private func send() {
        if voice.isRecording {
            Task {
                await voice.stop()
                model.send()
            }
        } else {
            model.send()
        }
    }
}

/// A square, rounded thumbnail of a stored image, decoded off the main thread at display size.
struct AttachmentThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UnalomeRadius.control, style: .continuous)
        ZStack {
            UnalomeColor.glassFill
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.strokeBorder(UnalomeColor.glassBorder, lineWidth: 1) }
        .accessibilityLabel("Attached image")
        .task(id: url) {
            let pixels = Int(side * displayScale)
            image = await Task.detached(priority: .userInitiated) {
                ThumbnailDecoder.thumbnail(at: url, maxPixelSize: pixels)
            }.value
        }
    }
}

/// The note above the first message the model still sees.
private struct ContextLimitNote: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(UnalomeColor.glassBorder).frame(height: 1)
            Text("Earlier messages are no longer seen by the model")
                .unalomeText(.footnote)
                .foregroundStyle(UnalomeColor.textTertiary)
                .multilineTextAlignment(.center)
                .layoutPriority(1)
            Rectangle().fill(UnalomeColor.glassBorder).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model pill and loading

/// The current model's name; opens a menu to switch models, to pick this chat's persona and,
/// for models that can reason, to switch thinking on or off for this chat.
private struct ModelPill: View {
    let services: AppServices
    @Bindable var model: ChatViewModel
    let onManagePersonas: () -> Void
    @Query(sort: \Persona.createdAt) private var personas: [Persona]

    var body: some View {
        let options = services.engineOptions()
        Menu {
            Section("Model") {
                ForEach(options) { option in
                    Button {
                        Task { await services.select(option.choice) }
                    } label: {
                        if option.choice == services.host.choice {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                        Text(option.detail)
                    }
                    .disabled(!option.isEnabled)
                }
            }
            Section("Persona") {
                Picker("Persona", selection: personaSelection(options: options)) {
                    Text("None").tag(UUID?.none)
                    ForEach(personas) { persona in
                        Text(persona.name).tag(Optional(persona.id))
                    }
                }
                .pickerStyle(.inline)
                Button("Manage personas…", systemImage: "person.crop.square", action: onManagePersonas)
            }
            if model.supportsThinking {
                Section {
                    Toggle(isOn: $model.isThinkingEnabled) {
                        Label("Thinking", systemImage: "brain")
                        Text("Reason before answering. Slower, shown apart from the reply.")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if model.supportsThinking && model.isThinkingEnabled {
                    Image(systemName: "brain")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .unalomeText(.footnote)
        }
        .disabled(model.isGenerating)
        .accessibilityLabel(
            "Model: \(services.host.engine.displayName)"
                + (model.persona.map { ", persona \($0.name)" } ?? "")
                + (model.supportsThinking && model.isThinkingEnabled ? ", thinking on" : ""))
        .accessibilityHint("Choose another model or persona, or switch thinking")
    }

    private var label: String {
        if let persona = model.persona {
            return "\(persona.name) · \(services.host.engine.displayName)"
        }
        return services.host.engine.displayName
    }

    /// Choosing a persona applies from the next reply and switches to its model, if it has one
    /// that can be used here.
    private func personaSelection(options: [EngineOption]) -> Binding<UUID?> {
        Binding(
            get: { model.persona?.id },
            set: { id in
                let persona = personas.first { $0.id == id }
                model.persona = persona
                if let raw = persona?.defaultModel, let choice = EngineChoice(rawValue: raw),
                   choice != services.host.choice,
                   options.contains(where: { $0.choice == choice && $0.isEnabled }) {
                    Task { await services.select(choice) }
                }
            })
    }
}

/// Shown instead of the status pill while the model loads.
private struct LoadingPill: View {
    let engineName: String
    let progress: Double

    var body: some View {
        Pill {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progress > 0 ? "Loading \(engineName) · \(Int(progress * 100))%" : "Loading \(engineName)…")
                    .unalomeText(.footnote)
                    .foregroundStyle(UnalomeColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Layout and focus

extension View {
    /// Caps the width at a comfortable line length and centres it (iPad, Mac).
    func readableWidth(_ width: CGFloat = 760) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

extension FocusedValues {
    /// The chat in the focused window, for the Chat menu (stop) on iPad and Mac.
    @Entry public var chatModel: ChatViewModel?
}

/// Opens the app's page in Settings, where a denied permission can be allowed.
struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings") {
            #if os(iOS)
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            #else
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                openURL(url)
            }
            #endif
        }
        .unalomeText(.footnote)
        .buttonStyle(.borderless)
        .foregroundStyle(UnalomeColor.emerald)
        .frame(minHeight: 44)
    }
}
