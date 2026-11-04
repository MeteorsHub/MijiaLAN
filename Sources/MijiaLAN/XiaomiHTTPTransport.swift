import Foundation
import MijiaCore

/// Default TLS validation, no persistent cookies, and a fresh redirect guard for every request.
public struct XiaomiHTTPTransport: MiHTTPTransport {
    private let session: URLSession
    private let followRedirects: Bool

    public init(followRedirects: Bool = true) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        self.followRedirects = followRedirects
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        try XiaomiEndpointPolicy.validate(url)
        let guardDelegate = XiaomiRedirectGuard(followRedirects: followRedirects)
        let (data, response) = try await session.data(for: request, delegate: guardDelegate)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

final class XiaomiRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 5
    private let followRedirects: Bool

    init(followRedirects: Bool) { self.followRedirects = followRedirects }

    func permits(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard followRedirects, remaining > 0, (try? XiaomiEndpointPolicy.validate(url)) != nil else { return false }
        remaining -= 1
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, permits(url) else { return nil }
        return request
    }
}
