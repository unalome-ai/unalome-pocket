import ChatCore
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import Features

/// Records what it is asked and answers "ok".
private final class RecordingEngine: ChatEngine, Sendable {
    struct Call: Sendable {
        var turn: ChatTurn
        var history: [ChatTurn]
        var options: GenerationOptions
    }

    let displayName = "Recorder"
    let capabilities: EngineCapabilities
    let calls = Mutex<[Call]>([])

    init(maxContextTokens: Int = 8192, supportsVision: Bool = true) {
        capabilities = EngineCapabilities(supportsVision: supportsVision, maxContextTokens: maxContextTokens)
    }

    func load(progress: @Sendable (Double) -> Void) async throws { progress(1) }
    func unload() async {}

    func reply(to turn: ChatTurn, history: [ChatTurn], options: GenerationOptions) -> AsyncThrowingStream<GenerationEvent, Error> {
        calls.withLock { $0.append(Call(turn: turn, history: history, options: options)) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token(String(repeating: "word ", count: 120)))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    var last: Call? { calls.withLock { $0.last } }
}

@MainActor
struct PersonaContextAttachmentTests {
    private let container: ModelContainer
    private let attachments: AttachmentStore
    private let store: ConversationStore
    private let conversation: Conversation

    init() throws {
        container = try ConversationStore.makeContainer(inMemory: true)
        let directory = FileManager.default.temporaryDirectory.appending(path: "FeaturesTests-\(UUID().uuidString)")
        attachments = AttachmentStore(directory: directory)
        store = ConversationStore(context: container.mainContext, attachments: attachments)
        conversation = try store.createConversation()
    }

    private func makeModel(_ engine: RecordingEngine) -> ChatViewModel {
        ChatViewModel(conversation: conversation, store: store, host: EngineHost(choice: .scripted) { _ in engine })
    }

    private func send(_ text: String, with model: ChatViewModel) async {
        model.draft = text
        model.send()
        await model.waitForGeneration()
    }

    @Test func personaPromptIsTheSystemTurnAndItsTemperatureIsUsed() async throws {
        let personas = PersonaStore(context: container.mainContext)
        try personas.seedIfEmpty()
        let coder = try #require(try personas.all().first { $0.starterKey == "coder" })
        let engine = RecordingEngine()
        let model = makeModel(engine)

        await send("Hello", with: model)
        #expect(engine.last?.history.isEmpty == true)
        #expect(engine.last?.options.temperature == 0.7)

        // A change mid-chat applies from the next reply, and is remembered by the chat.
        model.persona = coder
        #expect(conversation.personaID == coder.id)
        await send("Write a loop", with: model)
        let call = try #require(engine.last)
        #expect(call.history.first == ChatTurn(role: .system, text: coder.systemPrompt))
        #expect(call.history.dropFirst().map(\.role) == [.user, .assistant])
        #expect(call.options.temperature == coder.temperature)

        model.persona = nil
        await send("Thanks", with: model)
        #expect(engine.last?.history.contains { $0.role == .system } == false)
    }

    @Test func longChatsDropTheOldestTurnsAndMarkTheBoundary() async throws {
        // 1024 reply tokens + a small window: only the newest turns fit.
        let engine = RecordingEngine(maxContextTokens: 1600)
        let model = makeModel(engine)
        for index in 1...4 {
            await send("Question \(index) " + String(repeating: "detail ", count: 40), with: model)
        }
        let call = try #require(engine.last)
        #expect(call.history.count < model.messages.count - 2)
        #expect(call.history.first?.role == .user)
        let boundary = try #require(model.contextBoundaryMessageID)
        let boundaryMessage = try #require(model.messages.first { $0.id == boundary })
        #expect(boundaryMessage.role == .user)
        #expect(call.history.first?.text == boundaryMessage.text)

        // A short chat shows no note.
        let fresh = ChatViewModel(
            conversation: try store.createConversation(), store: store,
            host: EngineHost(choice: .scripted) { _ in RecordingEngine() })
        await send("Hi", with: fresh)
        #expect(fresh.contextBoundaryMessageID == nil)
    }

    @Test func attachedImagesAreSentWithTheMessage() async throws {
        let engine = RecordingEngine()
        let model = makeModel(engine)
        #expect(model.supportsImages)
        model.attachImage(try Self.pngData())
        let name = try #require(model.draftAttachments.first)
        #expect(model.canSend)  // an image alone can be sent

        await send("What colour is this?", with: model)

        #expect(model.draftAttachments.isEmpty)
        #expect(model.messages.first?.attachmentNames == [name])
        #expect(engine.last?.turn.images == [attachments.url(for: name)])
    }

    @Test func discardedDraftImagesAreDeleted() throws {
        let model = makeModel(RecordingEngine())
        model.attachImage(try Self.pngData())
        model.attachImage(try Self.pngData())
        let names = model.draftAttachments
        model.removeDraftAttachment(names[0])
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: names[0]).path))
        model.discardDraftAttachments()
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: names[1]).path))
        #expect(model.draftAttachments.isEmpty)
    }

    @Test func imagesAreNotOfferedForTextOnlyModels() {
        #expect(!makeModel(RecordingEngine(supportsVision: false)).supportsImages)
    }

    static func pngData() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
