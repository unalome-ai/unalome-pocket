import Foundation

/// Turns download, Hugging Face and storage errors into plain words a first-time user can act on.
/// Pure, so every case is tested.
public enum PlainErrorMessage {
    public static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return network(urlError.code)
        }
        if let download = error as? DownloadError {
            switch download {
            case .badStatus(let status): return httpStatus(status) ?? download.localizedDescription
            default: return download.localizedDescription
            }
        }
        if let hub = error as? HubAPI.HubError {
            if case .badResponse(let status) = hub, let message = httpStatus(status) { return message }
            return hub.localizedDescription
        }
        if isOutOfSpace(error) {
            return "This device ran out of storage during the download. Free up some space and tap Resume: "
                + "the download continues where it stopped."
        }
        return error.localizedDescription
    }

    static func network(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive:
            return "No internet connection. The download is paused where it stopped and continues when you "
                + "tap Resume. Chats with installed models work offline."
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
            return "Hugging Face could not be reached. Check the connection and try again; "
                + "the download continues where it stopped."
        default:
            return "The download was interrupted (\(code.rawValue)). Try again; it continues where it stopped."
        }
    }

    /// Hugging Face answers that need a plain explanation; `nil` for the rest.
    static func httpStatus(_ status: Int) -> String? {
        switch status {
        case 401, 403:
            return "This model needs a Hugging Face account or licence approval to download, which this app does not use."
        case 404:
            return "This model or one of its files is no longer on Hugging Face."
        case 429:
            return "Hugging Face is limiting downloads right now. Wait a few minutes and try again."
        case 500...599:
            return "Hugging Face is having trouble right now. Try again later."
        default:
            return nil
        }
    }

    static func isOutOfSpace(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }
}
