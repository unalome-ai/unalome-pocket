import Foundation
import Testing
@testable import ModelCatalog

struct PlainErrorMessageTests {
    @Test func offlineDuringDownload() {
        let message = PlainErrorMessage.describe(URLError(.notConnectedToInternet))
        #expect(message.hasPrefix("No internet connection."))
        #expect(message.contains("work offline"))
        #expect(PlainErrorMessage.describe(URLError(.networkConnectionLost)) == message)
        #expect(PlainErrorMessage.describe(URLError(.timedOut)).hasPrefix("Hugging Face could not be reached."))
    }

    @Test(arguments: [
        (401, "needs a Hugging Face account"), (403, "needs a Hugging Face account"),
        (404, "no longer on Hugging Face"), (429, "limiting downloads"), (503, "having trouble"),
    ])
    func huggingFaceStatuses(_ status: Int, _ phrase: String) {
        #expect(PlainErrorMessage.describe(DownloadError.badStatus(status)).contains(phrase))
        #expect(PlainErrorMessage.describe(HubAPI.HubError.badResponse(status)).contains(phrase))
    }

    @Test func otherStatusesKeepTheirOwnText() {
        #expect(PlainErrorMessage.describe(DownloadError.badStatus(418)) == DownloadError.badStatus(418).localizedDescription)
        #expect(PlainErrorMessage.describe(HubAPI.HubError.gated) == HubAPI.HubError.gated.localizedDescription)
    }

    @Test func storageRunningOutMidDownload() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(PlainErrorMessage.describe(posix).contains("ran out of storage"))
        #expect(PlainErrorMessage.describe(CocoaError(.fileWriteOutOfSpace)).contains("ran out of storage"))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(PlainErrorMessage.describe(wrapped).contains("ran out of storage"))
        // Checked before downloading too.
        let before = DownloadError.notEnoughSpace(needed: 3 << 30, available: 1 << 30)
        #expect(PlainErrorMessage.describe(before).hasPrefix("Not enough free storage"))
    }
}

struct DeviceWordingTests {
    @Test func namesEachDevice() {
        #expect(DeviceProfile.Kind.phone.thisDevice == "this iPhone")
        #expect(DeviceProfile.Kind.pad.thisDevice == "this iPad")
        #expect(DeviceProfile.Kind.mac.thisDevice == "this Mac")
        #if os(macOS)
        #expect(DeviceProfile.currentKind == .mac)
        #endif
    }
}
