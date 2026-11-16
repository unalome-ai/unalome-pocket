#if DEBUG
import ChatCore
import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// App Store screenshot content. Debug builds only, and only with the launch argument
/// `-UnalomeScreenshotMode YES`; Release builds do not contain this file's code.
///
/// The chats live in an in-memory store and the photo in a temporary folder, so nothing is
/// written to the user's data. Replies come from the scripted engine under a catalog model's
/// name, so the screens look as they do with that model on a device.
enum ScreenshotMode {
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: "UnalomeScreenshotMode")
    }

    /// The model name the chats show.
    static let modelName = "Qwen 3.5 2B"

    static func makeEngine() -> any ChatEngine {
        ScriptedEngine(tokenDelay: .milliseconds(32), displayName: modelName) { prompt in
            script.first { prompt.hasPrefix($0.question) }.map { ($0.answer, $0.reasoning) }
        }
    }

    static func makeAttachments() throws -> AttachmentStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ScreenshotModeAttachments")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AttachmentStore(directory: directory)
    }

    // MARK: Content

    struct Exchange {
        let title: String
        let question: String
        let answer: String
        var reasoning = ""
        var reasoningSeconds: Double?
        var thinking = false
        var hasPhoto = false
        /// Minutes before now that the chat was last used.
        let minutesAgo: Double
    }

    static let castIron = Exchange(
        title: "Cast-iron pan care",
        question: "How do I look after a cast-iron pan?",
        answer: """
            A little care after each use keeps it non-stick for decades:

            - **Clean it warm.** Hot water and a brush; a drop of soap is fine.
            - **Dry it fully.** A minute on the hob stops rust.
            - **Oil it thinly.** Wipe on a few drops, then buff until it looks dry.

            Avoid soaking it or putting it in the dishwasher. If rust appears, scrub it off, \
            then oil the pan and bake it upside down at 230 °C for an hour.
            """,
        minutesAgo: 1)

    static let commute = Exchange(
        title: "Commute options",
        question: "Should I walk, cycle or take the bus for a 5 km commute?",
        answer: """
            For 5 km, cycling is usually the best balance:

            | | Time | Cost | Exercise |
            |---|---|---|---|
            | Walk | 60 min | Free | High |
            | Cycle | 18 min | Low | Medium |
            | Bus | 25 min | Fare | Low |

            Cycle on dry days, and keep the bus for rain or heavy bags.
            """,
        reasoning: """
            5 km at walking pace, about 5 km/h, is an hour. Cycling at 16–18 km/h is under \
            20 minutes. A bus adds waiting and stops, so around 25 minutes. A small table \
            compares them best.
            """,
        reasoningSeconds: 4,
        thinking: true,
        minutesAgo: 30)

    static let photo = Exchange(
        title: "Mountain lake photo",
        question: "What's in this photo?",
        answer: """
            A mountain lake at sunset. Three ridges fade from dark to pale blue towards the \
            horizon, and a low orange sun sits just above them. The water is calm, so it \
            mirrors the sun as a soft streak of light.

            The warm sky against the cool ridges gives it a quiet, end-of-day feel.
            """,
        hasPhoto: true,
        minutesAgo: 90)

    static let others: [Exchange] = [
        Exchange(
            title: "Birthday note for Ana",
            question: "Write a short birthday note for my sister Ana.",
            answer: "Happy birthday, Ana! Thank you for every late-night talk and terrible pun. Here's to your best year yet.",
            minutesAgo: 60 * 5),
        Exchange(
            title: "Compound interest",
            question: "Explain compound interest in two sentences.",
            answer: "You earn interest on your savings and on the interest they have already earned. Over years, that snowball grows much faster than simple interest.",
            minutesAgo: 60 * 26),
        Exchange(
            title: "Sourdough schedule",
            question: "Give me a weekend sourdough schedule.",
            answer: "Friday 9 pm: feed the starter. Saturday 9 am: mix, then fold every 30 minutes for 2 hours. Shape at 3 pm, proof overnight in the fridge, and bake Sunday morning.",
            minutesAgo: 60 * 50),
        Exchange(
            title: "Hiking packing list",
            question: "What should I pack for a day hike?",
            answer: "Water, snacks, a light rain jacket, sun cream, a charged phone with an offline map, a small first-aid kit and a warm layer.",
            minutesAgo: 60 * 24 * 4),
    ]

    static var script: [Exchange] { [castIron, commute, photo] + others }

    /// Adds the chats, oldest first, to an empty in-memory store.
    @MainActor
    static func seed(_ store: ConversationStore) throws {
        for exchange in script.sorted(by: { $0.minutesAgo > $1.minutesAgo }) {
            let chat = try store.createConversation()
            let date = Date.now.addingTimeInterval(-exchange.minutesAgo * 60)
            chat.createdAt = date
            chat.isThinkingEnabled = exchange.thinking
            var names: [String] = []
            if exchange.hasPhoto, let attachments = store.attachments, let data = lakeImage() {
                names = [try attachments.save(imageData: data)]
            }
            try store.appendMessage(role: .user, text: exchange.question, attachmentNames: names, to: chat)
            let reply = try store.appendMessage(role: .assistant, text: exchange.answer, to: chat)
            reply.reasoning = exchange.reasoning
            reply.reasoningSeconds = exchange.reasoningSeconds
            try store.rename(chat, to: exchange.title)
            chat.updatedAt = date
            try store.save()
        }
    }

    // MARK: The photo

    /// A simple generated picture: mountain ridges and a sun over a lake, no people or marks.
    static func lakeImage(width: Int = 1200, height: Int = 900) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
        let horizon = h * 0.42

        // Sky (Core Graphics has the origin at the bottom left).
        let sky = CGGradient(
            colorsSpace: space,
            colors: [color(0.98, 0.62, 0.36), color(0.55, 0.42, 0.62), color(0.16, 0.20, 0.38)] as CFArray,
            locations: [0, 0.45, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: h), options: [])

        // Sun.
        context.setFillColor(color(1, 0.62, 0.30))
        let sunSize = h * 0.11
        let sunX = w * 0.62
        context.fillEllipse(in: CGRect(x: sunX - sunSize / 2, y: horizon + h * 0.30, width: sunSize, height: sunSize))

        // Ridges, far to near.
        let ridges: [(CGFloat, CGFloat, CGColor)] = [
            (0.24, 2.2, color(0.44, 0.47, 0.64)),
            (0.16, 1.6, color(0.27, 0.31, 0.47)),
            (0.09, 1.2, color(0.13, 0.16, 0.27)),
        ]
        for (index, (peak, frequency, fill)) in ridges.enumerated() {
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: horizon))
            for step in 0...60 {
                let x = w * CGFloat(step) / 60
                let wave = sin(CGFloat(step) / 60 * .pi * frequency + CGFloat(index)) * 0.5 + 0.5
                let jag = sin(CGFloat(step) * 0.9 + CGFloat(index) * 2) * 0.04
                context.addLine(to: CGPoint(x: x, y: horizon + h * peak * (wave * 0.7 + 0.3 + jag)))
            }
            context.addLine(to: CGPoint(x: w, y: horizon))
            context.closePath()
            context.setFillColor(fill)
            context.fillPath()
        }

        // Water with the sun's reflection.
        let water = CGGradient(
            colorsSpace: space, colors: [color(0.07, 0.10, 0.18), color(0.22, 0.25, 0.40)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(water, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizon), options: [])
        for line in 0..<9 {
            let y = horizon - CGFloat(line + 1) * h * 0.035
            let half = h * 0.06 * (1 - CGFloat(line) / 10)
            context.setFillColor(CGColor(red: 1, green: 0.66, blue: 0.36, alpha: 0.55 - CGFloat(line) * 0.05))
            context.fill(CGRect(x: sunX - half, y: y, width: half * 2, height: h * 0.008))
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif

#if DEBUG && os(macOS)
import AppKit

extension ScreenshotMode {
    /// Sizes the window to 1440 × 900 points, the Mac App Store screenshot size at 2x.
    @MainActor
    static func sizeMacWindow() {
        guard isOn, let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }
        let origin = window.screen?.visibleFrame.origin ?? .zero
        window.setFrame(NSRect(x: origin.x + 20, y: origin.y + 20, width: 1440, height: 900), display: true)
    }
}
#endif
