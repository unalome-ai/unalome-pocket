import Foundation
import Testing
@testable import PocketShared

struct AppRouteTests {
    static let id = UUID(uuidString: "4F1B6C2E-8D0A-4E7B-9C3D-2A1F0E9B8C7D")!

    @Test(arguments: [
        AppRoute.newChat, .voice, .ask("What's the capital of France?"), .ask("a & b = c? #1 / ünïcode"),
        .conversation(id),
    ])
    func roundTripsThroughItsURL(_ route: AppRoute) {
        #expect(route.url.scheme == "unalomepocket")
        #expect(AppRoute(url: route.url) == route)
    }

    @Test func parsesHandWrittenURLs() throws {
        #expect(AppRoute(url: try #require(URL(string: "unalomepocket://new"))) == .newChat)
        #expect(AppRoute(url: try #require(URL(string: "UnalomePocket://VOICE"))) == .voice)
        #expect(AppRoute(url: try #require(URL(string: "unalomepocket://ask?q=Hello%20there"))) == .ask("Hello there"))
        #expect(
            AppRoute(url: try #require(URL(string: "unalomepocket://conversation/\(Self.id.uuidString)")))
                == .conversation(Self.id))
    }

    @Test func anEmptyQuestionOpensANewChat() throws {
        #expect(AppRoute(url: try #require(URL(string: "unalomepocket://ask"))) == .newChat)
        #expect(AppRoute(url: try #require(URL(string: "unalomepocket://ask?q=%20%20"))) == .newChat)
    }

    @Test func rejectsOtherURLs() throws {
        for text in [
            "https://unalome.ai/new", "unalomepocket://", "unalomepocket://settings",
            "unalomepocket://conversation/not-a-uuid", "unalomepocket://conversation",
        ] {
            #expect(AppRoute(url: try #require(URL(string: text))) == nil, "\(text)")
        }
    }

    @Test @MainActor func inboxHandsARouteOverOnce() {
        let inbox = RouteInbox()
        inbox.post(.voice)
        #expect(inbox.pending == .voice)
        #expect(inbox.take() == .voice)
        #expect(inbox.take() == nil)
    }
}

struct WidgetSnapshotTests {
    private func store() throws -> WidgetSnapshotStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshot-\(UUID().uuidString)")
        return WidgetSnapshotStore(directory: directory)
    }

    @Test func writesReadsAndClears() throws {
        let store = try store()
        #expect(store.read() == nil)
        let snapshot = WidgetSnapshot(
            conversationID: UUID(), title: "Moon facts", replyExcerpt: "The Moon is tidally locked.",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try store.write(snapshot))
        #expect(store.read() == snapshot)
        #expect(try !store.write(snapshot), "an unchanged snapshot is not rewritten")
        #expect(try store.write(nil))
        #expect(store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func ignoresAnUnreadableFile() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
    }

    @Test(arguments: [
        ("Hello! How can I help?", "Hello! How can I help?"),
        ("## Facts\n\nThe Moon...", "Facts"),
        ("\n\n- **Bold** item with `code`", "Bold item with code"),
        ("> A quote\nmore", "A quote"),
        ("```swift\nlet x = 1\n```", "let x = 1"),
        ("", ""),
    ])
    func excerptIsPlainFirstLine(_ input: String, _ expected: String) {
        #expect(WidgetSnapshot.excerpt(fromReply: input) == expected)
    }

    @Test func excerptIsCutAtAWord() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let excerpt = WidgetSnapshot.excerpt(fromReply: long, maxLength: 22)
        #expect(excerpt == "word word word word…")
    }
}

struct DownloadActivityContentTests {
    @Test func fractionAndText() {
        let content = DownloadActivityContent(bytesDone: 250, totalBytes: 1000, phase: .downloading)
        #expect(content.fraction == 0.25)
        #expect(content.percentText == "25%")
        #expect(content.statusText == "Downloading")
        #expect(!content.isFinal)
        #expect(DownloadActivityContent(bytesDone: 0, totalBytes: 0, phase: .downloading).fraction == 0)
        #expect(DownloadActivityContent(bytesDone: 5, totalBytes: 10, phase: .done).fraction == 1)
        #expect(DownloadActivityContent(bytesDone: 5, totalBytes: 10, phase: .failed).isFinal)
    }

    @Test func pausedInTheBackgroundAsksToOpenTheApp() {
        let paused = DownloadActivityContent(bytesDone: 5, totalBytes: 10, phase: .paused, pausedForBackground: true)
        #expect(paused.statusText == "Paused — open the app to continue")
        #expect(DownloadActivityContent(bytesDone: 5, totalBytes: 10, phase: .paused).statusText == "Paused")
    }

    @Test func throttleSendsAboutOnceASecondButAlwaysOnPhaseChanges() {
        var throttle = ActivityUpdateThrottle(interval: 1)
        let start = Date(timeIntervalSince1970: 0)
        func content(_ done: Int64, _ phase: DownloadActivityContent.Phase = .downloading) -> DownloadActivityContent {
            DownloadActivityContent(bytesDone: done, totalBytes: 100, phase: phase)
        }
        var sent: [Bool] = []
        sent.append(throttle.shouldSend(content(1), at: start))
        sent.append(throttle.shouldSend(content(2), at: start.addingTimeInterval(0.3)))
        sent.append(throttle.shouldSend(content(3), at: start.addingTimeInterval(0.9)))
        sent.append(throttle.shouldSend(content(4), at: start.addingTimeInterval(1.0)))
        sent.append(throttle.shouldSend(content(4, .verifying), at: start.addingTimeInterval(1.1)))
        sent.append(throttle.shouldSend(content(100, .done), at: start.addingTimeInterval(1.2)))
        #expect(sent == [true, false, false, true, true, true])
    }
}
