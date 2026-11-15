import ChatCore
import SwiftUI
import UnalomeDesign

/// One conversation: the message list, the status pill and the composer.
public struct ChatView: View {
    @State private var model: ChatViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let services: AppServices

    public init(conversation: Conversation, store: ConversationStore, services: AppServices) {
        let model = ChatViewModel(conversation: conversation, store: store, host: services.host)
        model.onReplyFinished = { choice, metrics in services.record(metrics, for: choice) }
        _model = State(initialValue: model)
        self.services = services
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(model.messages) { message in
                    MessageRow(message: message, model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
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
            ComposerArea(model: model)
        }
        .background(UnalomeColor.background)
        .navigationTitle(model.conversation.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelPill(services: services, model: model)
            }
        }
        // Leaving the conversation stops the reply and keeps what was written so far.
        .onDisappear { model.stop() }
        // iOS does not allow GPU work in the background, so stop before the app is suspended.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop() }
        }
    }
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
            MarkdownText(message.text)
                .foregroundStyle(UnalomeColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(UnalomeColor.glassFill, in: shape)
                .overlay { shape.strokeBorder(UnalomeGradient.brand, lineWidth: 1) }
        }
        .contextMenu {
            CopyButton(text: message.text)
            if message.id == model.lastUserMessage?.id, !model.isGenerating {
                Button("Edit", systemImage: "pencil") { model.beginEditing(message) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(message.text)")
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
                if message.stoppedAtLengthLimit {
                    HStack(spacing: 10) {
                        Text("Stopped at the length limit")
                            .unalomeText(.footnote)
                            .foregroundStyle(UnalomeColor.textSecondary)
                        if message.id == model.messages.last?.id, model.canContinue {
                            Button("Continue", action: model.continueReply)
                                .unalomeText(.footnote)
                                .buttonStyle(.borderless)
                                .foregroundStyle(UnalomeColor.emerald)
                        }
                    }
                }
                HStack(spacing: 4) {
                    CopyButton(text: message.text)
                    if message.id == model.messages.last?.id, model.canRegenerate {
                        Button("Regenerate", systemImage: "arrow.clockwise", action: model.regenerate)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(UnalomeColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { CopyButton(text: message.text) }
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
                GradientText("this phone.")
            }
            .unalomeText(.display)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Replies are written on this device, and your chats are stored only here.")
                .unalomeText(.callout)
                .foregroundStyle(UnalomeColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

// MARK: - Composer

private struct ComposerArea: View {
    @Bindable var model: ChatViewModel

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

            Composer(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct Composer: View {
    @Bindable var model: ChatViewModel
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .unalomeText(.body)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.vertical, 8)
                .onSubmit(model.send)

            if model.isGenerating {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                        .frame(width: buttonSize, height: buttonSize)
                        .background(UnalomeColor.textPrimary, in: Circle())
                        .foregroundStyle(UnalomeColor.background)
                }
                .accessibilityLabel("Stop generating")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.bold)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(UnalomeGradient.brand, in: Circle())
                        .foregroundStyle(UnalomeColor.background)
                }
                .disabled(!model.canSend)
                .opacity(model.canSend ? 1 : 0.4)
                .accessibilityLabel(model.editingMessage == nil ? "Send" : "Send edited message")
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .liquidGlass(in: RoundedRectangle(cornerRadius: UnalomeRadius.card, style: .continuous), interactive: true)
    }
}

// MARK: - Model pill and loading

/// The current model's name; opens a menu to switch models and, for models that can reason,
/// to switch thinking on or off for this chat.
private struct ModelPill: View {
    let services: AppServices
    @Bindable var model: ChatViewModel

    var body: some View {
        Menu {
            Section {
                ForEach(services.engineOptions()) { option in
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
                Text(services.host.engine.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .unalomeText(.footnote)
        }
        .disabled(model.isGenerating)
        .accessibilityLabel(
            "Model: \(services.host.engine.displayName)"
                + (model.supportsThinking && model.isThinkingEnabled ? ", thinking on" : ""))
        .accessibilityHint("Choose another model or switch thinking")
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
