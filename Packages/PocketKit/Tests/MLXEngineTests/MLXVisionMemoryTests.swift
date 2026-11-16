import ChatCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MLX
import ModelCatalog
import Testing
import UniformTypeIdentifiers
@testable import MLXEngine

/// Measures memory when a chat switches from the text model to the vision model, and what an
/// image costs at different sizes.
///
/// Opt-in; downloads every model it measures:
///
///     POCKETKIT_MLX_VISION_MEMORY=1 POCKETKIT_MLX_MODEL_DIR=… \
///     POCKETKIT_MLX_VISION_MODELS=mlx-community/Qwen3.5-0.8B-4bit,mlx-community/Qwen3.5-4B-MLX-4bit \
///     swift test --filter MLXVisionMemoryTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["POCKETKIT_MLX_VISION_MEMORY"] == "1"))
struct MLXVisionMemoryTests {
    private static var modelIDs: [String] {
        let list = ProcessInfo.processInfo.environment["POCKETKIT_MLX_VISION_MODELS"] ?? "mlx-community/Qwen3.5-0.8B-4bit"
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Longest sides to compare; `0` means the engine's own default.
    private static var imageSizes: [Int] {
        let list = ProcessInfo.processInfo.environment["POCKETKIT_MLX_IMAGE_SIZES"] ?? "0"
        return list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static var storageRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["POCKETKIT_MLX_MODEL_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appending(path: "PocketKitMLXIntegration")
    }

    private static func installed(_ id: String) async throws -> (URL, CatalogEntry) {
        let storage = ModelStorage(root: storageRoot)
        let entry = try #require(try CatalogLoader.bundled().models.first { $0.id == id })
        if storage.isInstalled(id) {
            return (storage.directory(for: id), entry)
        }
        return (try await ModelDownloader(storage: storage).download(entry) { _ in }, entry)
    }

    private static func mb(_ bytes: Int?) -> String {
        bytes.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "?"
    }

    private static func drain(_ engine: MLXChatEngine, _ text: String, images: [URL] = [], maxTokens: Int) async throws -> String {
        var reply = ""
        for try await event in engine.reply(
            to: ChatTurn(role: .user, text: text, images: images), history: [],
            options: GenerationOptions(temperature: 0, maxTokens: maxTokens))
        {
            if case .token(let token) = event { reply += token }
        }
        return reply
    }

    @Test(.timeLimit(.minutes(60)))
    func switchingToTheVisionModelFreesTheTextModel() async throws {
        let image = try Self.receiptImage()
        for id in Self.modelIDs {
            let (directory, entry) = try await Self.installed(id)
            for size in Self.imageSizes {
                try await measure(directory: directory, entry: entry, size: size, image: image)
                MLX.Memory.clearCache()
                print("MLX vision memory [\(entry.displayName)] after the engine is gone: active \(Self.mb(MLX.Memory.activeMemory))")
            }
        }
    }

    private func measure(directory: URL, entry: CatalogEntry, size: Int, image: URL) async throws {
        do {
            do {
                MLX.Memory.clearCache()
                let engine = MLXChatEngine(
                    directory: directory, displayName: entry.displayName, supportsThinking: entry.supportsThinking,
                    supportsVision: true,
                    reusesConversation: ProcessInfo.processInfo.environment["POCKETKIT_MLX_NO_REUSE"] != "1",
                    maxImageDimension: size == 0 ? nil : size)
                try await engine.load { _ in }
                if ProcessInfo.processInfo.environment["POCKETKIT_MLX_SKIP_TEXT_TURN"] != "1" {
                    _ = try await Self.drain(engine, "Say hello.", maxTokens: 8)
                }
                let textActive = MLX.Memory.activeMemory
                let textPeak = MLX.Memory.peakMemory

                MLX.Memory.peakMemory = 0
                let answer = try await Self.drain(
                    engine, "Read the receipt. What is the TOTAL, and what is the order number in the small print at the bottom?",
                    images: [image], maxTokens: 80)
                let imagePeak = MLX.Memory.peakMemory
                let visionActive = MLX.Memory.activeMemory
                let beforeLoad = engine.activeBytesBeforeVisionLoad
                let footprint = ProcessMemory.footprintBytes()
                print("""
                    MLX vision memory [\(entry.displayName), image \(size == 0 ? "default" : "\(size) px")]: \
                    text model \(Self.mb(textActive)) (text turn peak \(Self.mb(textPeak))), before VLM load \(Self.mb(beforeLoad)), \
                    image turn peak \(Self.mb(imagePeak)), vision model after \(Self.mb(visionActive)), \
                    process footprint \(Self.mb(footprint.map(Int.init))), \
                    peak/vision \(String(format: "%.2f", Double(imagePeak) / Double(max(visionActive, 1)))), \
                    total correct: \(answer.contains("47.83")), order exact: \(answer.contains("5521-K"))
                    """)
                print("MLX vision memory [\(entry.displayName)] answer: \(answer.replacingOccurrences(of: "\n", with: " ").prefix(300))")
                #expect(engine.isUsingVisionModel)
                // The text model is gone before the vision model loads (what is left is MLX's own
                // state from the text turn, measured at about 17% of the text model for Qwen 3.5 4B).
                #expect(try #require(beforeLoad) < textActive / 4)
                // Holding both models measured 1.68× for Qwen 3.5 4B; with the text model released
                // it is 1.23× at 512 px and 1.36× at the 1024 px cap (512 px misses small print).
                if visionActive > 2 << 30 {
                    #expect(Double(imagePeak) <= Double(visionActive) * 1.4)
                }
                await engine.unload()
                print("MLX vision memory [\(entry.displayName)] after unload: active \(Self.mb(MLX.Memory.activeMemory)), cache \(Self.mb(MLX.Memory.cacheMemory))")
            }
        }
    }

    /// A 1536 × 1152 receipt: large items, a total, and an order number in small print.
    static func receiptImage() throws -> URL {
        let width = 1536, height = 1152
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: 368, y: 40, width: 800, height: 1072))

        func draw(_ text: String, size: CGFloat, x: CGFloat, y: CGFloat) {
            let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - y)
            CTLineDraw(line, context)
        }
        draw("CORNER CAFE", size: 48, x: 420, y: 130)
        let items = [("Flat white", "4.20"), ("Croissant", "3.10"), ("Soup of the day", "8.90"),
                     ("Sourdough loaf", "6.75"), ("Orange juice", "4.88"), ("Lunch special", "20.00")]
        for (index, item) in items.enumerated() {
            let y = 240 + CGFloat(index) * 60
            draw(item.0, size: 30, x: 420, y: y)
            draw(item.1, size: 30, x: 1000, y: y)
        }
        draw("TOTAL", size: 40, x: 420, y: 700)
        draw("47.83", size: 40, x: 980, y: 700)
        draw("Thank you for visiting. Order 5521-K, till 3, 14:07.", size: 15, x: 420, y: 1050)

        let url = FileManager.default.temporaryDirectory.appending(path: "pocketkit-receipt.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
