import Foundation
import Synchronization

/// An in-process HTTP server for tests: `URLProtocol` answers requests for one made-up host,
/// so tests can run in parallel without touching the network.
final class StubServer: Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
        /// Send only this many bytes, then stall until the request is cancelled.
        var stallAfter: Int?
    }

    typealias Handler = @Sendable (URLRequest) -> Response

    let host: String
    private final class RequestLog: Sendable {
        let requests = Mutex<[URLRequest]>([])
    }

    private let requestLog = RequestLog()

    init(handler: @escaping Handler) {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        StubProtocol.register(host: host) { [requestLog] request in
            requestLog.requests.withLock { $0.append(request) }
            return handler(request)
        }
    }

    deinit {
        StubProtocol.unregister(host: host)
    }

    var baseURL: URL {
        URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/")
    }

    var requests: [URLRequest] {
        requestLog.requests.withLock { $0 }
    }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let handlers = Mutex<[String: StubServer.Handler]>([:])

    static func register(host: String, handler: @escaping StubServer.Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        _ = handlers.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = handler(request)
        guard let http = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if let stallAfter = response.stallAfter {
            client?.urlProtocol(self, didLoad: response.body.prefix(stallAfter))
            return
        }
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension StubServer.Response {
    static func json(_ text: String) -> Self {
        Self(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    /// A file response that honours `Range: bytes=N-` like Hugging Face's CDN.
    static func file(_ data: Data, for request: URLRequest) -> Self {
        if let range = request.value(forHTTPHeaderField: "Range"),
            range.hasPrefix("bytes="), range.hasSuffix("-"),
            let start = Int(range.dropFirst("bytes=".count).dropLast())
        {
            return Self(status: 206, body: data.dropFirst(start))
        }
        return Self(status: 200, body: data)
    }
}
