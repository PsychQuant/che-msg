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

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
