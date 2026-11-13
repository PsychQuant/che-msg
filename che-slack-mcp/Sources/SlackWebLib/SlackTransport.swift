import Foundation

/// Sends one HTTP request to Slack. Injected into `SlackWebClient` so tests can
/// observe requests without network access (spec: slack-web-client,
/// "Session token request authentication").
public protocol SlackTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport. It follows no HTTP redirect (spec:
/// slack-web-client, "Session token request authentication"): a redirect
/// would send the `Cookie` header and the form body with the token to
/// another URL. A redirect answer is thrown as `SlackRedirectRefused`, which
/// the client reports as a network error.
public struct URLSessionTransport: SlackTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: URLSessionTransport.sessionConfiguration())) {
        self.session = session
    }

    /// A session that keeps no HTTP state from Slack's answers (spec:
    /// slack-web-client, "Session token request authentication"). Not
    /// `URLSession.shared`: it stores every `Set-Cookie` Slack sends in
    /// `~/Library/HTTPStorages/<executable>.binarycookies`, mode 0644, and
    /// sends it with every later request, to any workspace. Here nothing is
    /// stored or cached, and the only cookie sent is the `d` header the
    /// client writes.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Sends `request` on the session with `RedirectRefusal` as the task's
    /// delegate, so no session given to `init(session:)` follows a
    /// redirect. A refused redirect comes back as its 3xx answer, which is
    /// thrown.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: RedirectRefusal.shared)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if (300...399).contains(http.statusCode) {
            throw SlackRedirectRefused(status: http.statusCode)
        }
        return (data, http)
    }
}

/// Refuses every HTTP redirect, so the task ends with the redirect answer.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectRefusal()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Slack answered with a redirect (any 3xx status), which is not followed.
/// Holds only the status: the `Location` comes from outside and is not
/// repeated.
public struct SlackRedirectRefused: Error, LocalizedError, CustomStringConvertible {
    public let status: Int

    public var description: String {
        "Slack answered with a redirect (HTTP \(status)), which is not followed."
    }

    public var errorDescription: String? { description }
}
