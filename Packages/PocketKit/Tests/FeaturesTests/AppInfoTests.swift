import Foundation
import Testing
@testable import Features

struct ReportEmailTests {
    private func email(question: String? = "What is 2 + 2?", reply: String = "4 & more") -> ReportEmail {
        ReportEmail(question: question, reply: reply, modelName: "Qwen 3.5 2B", appVersion: "1.0 (3)", deviceName: "iPad")
    }

    @Test func prefillsTheReportAndNothingElse() {
        let report = email()
        #expect(report.recipient == AppLinks.supportEmail)
        #expect(report.body.contains("Model: Qwen 3.5 2B"))
        #expect(report.body.contains("App: Unalome Pocket 1.0 (3) on iPad"))
        #expect(report.body.contains("My message:\nWhat is 2 + 2?"))
        #expect(report.body.contains("The response:\n4 & more"))
        #expect(!email(question: nil).body.contains("My message:"))
    }

    @Test func linkIsAMailtoThatRoundTrips() throws {
        let url = try #require(email().url)
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:support@unalome.ai?"))
        #expect(!url.absoluteString.contains("+"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "body" }?.value == email().body)
        #expect(items.first { $0.name == "subject" }?.value == "Report a response from Unalome Pocket")
    }

    @Test func longTextsAreShortened() {
        let long = String(repeating: "a", count: 5000)
        let report = email(reply: long)
        #expect(report.body.contains("… [shortened]"))
        #expect(report.body.count < 2500)
    }

    @Test func explanationSaysNothingIsSentAutomatically() {
        #expect(ReportEmail.explanation.contains("Nothing is sent unless you send the email yourself"))
    }
}
