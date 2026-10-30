import Foundation

/// Sends one HTTP request to Slack. Injected into `SlackWebClient` so tests can
/// observe requests without network access (spec: slack-web-client,
/// "Session token request authentication").
public protocol SlackTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport.
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

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
