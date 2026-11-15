import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import ChatCore

struct ContextWindowTests {
    private func turn(_ role: ChatRole, _ characters: Int) -> ChatTurn {
        ChatTurn(role: role, text: String(repeating: "a", count: characters))
    }

    @Test func keepsEverythingThatFits() {
        let history = [ChatTurn(role: .system, text: "Be brief."), turn(.user, 70), turn(.assistant, 70)]
        let fit = ContextWindow.fit(history: history, turn: turn(.user, 70), contextTokens: 4096, replyTokens: 1024)
        #expect(fit.history == history)
        #expect(fit.droppedCount == 0)
    }

    @Test func dropsOldestTurnsAndKeepsTheSystemPrompt() {
        let system = ChatTurn(role: .system, text: "Be brief.")
        // Each 700-character turn is about 208 tokens.
        let conversation = (0..<10).map { turn($0.isMultiple(of: 2) ? .user : .assistant, 700) }
        let fit = ContextWindow.fit(
            history: [system] + conversation, turn: turn(.user, 700), contextTokens: 2048, replyTokens: 1024)

        #expect(fit.history.first == system)
        #expect(fit.droppedCount > 0)
        #expect(fit.history.count == 1 + conversation.count - fit.droppedCount)
        // The kept part is the newest turns and starts with a question.
        #expect(Array(fit.history.dropFirst()) == Array(conversation.suffix(conversation.count - fit.droppedCount)))
        #expect(fit.history[1].role == .user)
        let used = fit.history.map(ContextWindow.estimatedTokens).reduce(0, +)
            + ContextWindow.estimatedTokens(turn(.user, 700))
        #expect(used <= 2048 - 1024)
    }

    @Test func holdsBackAtMostHalfTheWindowForTheReply() {
        let history = [turn(.user, 700), turn(.assistant, 700)]
        let fit = ContextWindow.fit(history: history, turn: turn(.user, 70), contextTokens: 4096, replyTokens: 4096)
        #expect(fit.droppedCount == 0)
    }

    @Test func dropsEverythingWhenTheNewMessageAloneIsTooLong() {
        let history = [turn(.user, 100), turn(.assistant, 100)]
        let fit = ContextWindow.fit(history: history, turn: turn(.user, 20_000), contextTokens: 2048, replyTokens: 1024)
        #expect(fit.history.isEmpty)
        #expect(fit.droppedCount == 2)
    }

    @Test func imagesCountAgainstTheWindow() {
        let withImage = ChatTurn(role: .user, text: "What is this?", images: [URL(fileURLWithPath: "/tmp/a.jpg")])
        #expect(ContextWindow.estimatedTokens(withImage) > ContextWindow.estimatedTokens(ChatTurn(role: .user, text: "What is this?")) + 1000)
    }
}

@MainActor
struct PersonaStoreTests {
    private let container: ModelContainer
    private let store: PersonaStore

    init() throws {
        container = try ConversationStore.makeContainer(inMemory: true)
        store = PersonaStore(context: container.mainContext)
    }

    @Test func seedsFourPlainStartersInOrder() throws {
        try store.seedIfEmpty()
        let personas = try store.all()
        #expect(personas.map(\.name) == ["Assistant", "Writing editor", "Explainer", "Coder"])
        #expect(personas.allSatisfy { !$0.systemPrompt.isEmpty && $0.starterKey != nil })
        // Seeding again changes nothing.
        try store.seedIfEmpty()
        #expect(try store.all().count == 4)
    }

    @Test func starterPromptsAreNotCompanionPersonas() {
        let words = ["girlfriend", "boyfriend", "romantic", "flirt", "lover", "companion", "date"]
        for starter in PersonaStore.starters {
            let text = (starter.name + " " + starter.prompt).lowercased()
            #expect(!words.contains { text.contains($0) }, "\(starter.name)")
        }
    }

    @Test func seedOnceRespectsDeletingEverything() throws {
        let defaults = try #require(UserDefaults(suiteName: "PersonaStoreTests-\(UUID().uuidString)"))
        try store.seedOnce(defaults: defaults)
        for persona in try store.all() { try store.delete(persona) }
        try store.seedOnce(defaults: defaults)
        #expect(try store.all().isEmpty)
    }

    @Test func createEditDeleteAndRestore() throws {
        try store.seedIfEmpty()
        let mine = try store.create(
            name: "Travel planner", systemPrompt: "Plan trips.", temperature: 0.5, defaultModel: "local:org/model")
        #expect(store.persona(id: mine.id)?.defaultModel == "local:org/model")

        let coder = try #require(try store.all().first { $0.starterKey == "coder" })
        coder.systemPrompt = "Edited"
        try store.save()
        let editor = try #require(try store.all().first { $0.starterKey == "editor" })
        try store.delete(editor)
        #expect(try store.all().count == 4)

        try store.restoreStarters()
        let all = try store.all()
        #expect(all.count == 5)
        #expect(all.first { $0.starterKey == "coder" }?.systemPrompt == PersonaStore.starters[3].prompt)
        #expect(all.contains { $0.starterKey == "editor" })
        #expect(all.last?.name == "Travel planner")
    }
}

@MainActor
struct AttachmentStoreTests {
    /// A 3000 × 2000 PNG with a GPS block, standing in for a camera photo.
    static func photoData() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 44.4, kCGImagePropertyGPSLongitude: 26.1],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func savesADownscaledJPEGWithoutLocation() throws {
        let attachments = AttachmentStore(directory: try temporaryDirectory())
        let name = try attachments.save(imageData: try Self.photoData())
        #expect(name.hasSuffix(".jpg"))

        let source = try #require(CGImageSourceCreateWithURL(attachments.url(for: name) as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == AttachmentStore.maxPixelSize)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1024)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func rejectsDataThatIsNotAnImage() throws {
        let attachments = AttachmentStore(directory: try temporaryDirectory())
        #expect(throws: AttachmentStore.AttachmentError.self) {
            try attachments.save(imageData: Data("not an image".utf8))
        }
    }

    @Test func filesGoWithTheirMessagesAndConversations() throws {
        let container = try ConversationStore.makeContainer(inMemory: true)
        let attachments = AttachmentStore(directory: try temporaryDirectory())
        let store = ConversationStore(context: container.mainContext, attachments: attachments)
        let photo = try Self.photoData()

        let conversation = try store.createConversation()
        let first = try attachments.save(imageData: photo)
        let message = try store.appendMessage(role: .user, text: "What is this?", attachmentNames: [first], to: conversation)
        #expect(message.turn(attachments: attachments).images == [attachments.url(for: first)])
        try store.deleteMessages([message])
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: first).path))

        let second = try attachments.save(imageData: photo)
        _ = try store.appendMessage(role: .user, text: "And this?", attachmentNames: [second], to: conversation)
        try store.delete(conversation)
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: second).path))
    }

    @Test func removesFilesNoMessageUses() throws {
        let container = try ConversationStore.makeContainer(inMemory: true)
        let attachments = AttachmentStore(directory: try temporaryDirectory())
        let store = ConversationStore(context: container.mainContext, attachments: attachments)
        let photo = try Self.photoData()
        let kept = try attachments.save(imageData: photo)
        let orphan = try attachments.save(imageData: photo)
        _ = try store.appendMessage(role: .user, text: "", attachmentNames: [kept], to: try store.createConversation())

        try store.removeUnreferencedAttachments()

        #expect(FileManager.default.fileExists(atPath: attachments.url(for: kept).path))
        #expect(!FileManager.default.fileExists(atPath: attachments.url(for: orphan).path))
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ChatCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
