import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Session token request
/// authentication": the production transport does not follow redirects, so
/// neither the `Cookie` header nor the form body with the token is sent to
/// another URL. No request leaves the process: `RedirectStub` answers every
/// request of a session configured with it.
@Suite("Transport refuses redirects", .serialized)
struct TransportRedirectTests {
    let credential = SlackCredential(teamID: "T01", token: "xoxc-1", cookie: "xoxd-fake%2Fredirect")

    /// `URLSessionTransport.sessionConfiguration()` with every request
    /// answered by `RedirectStub`.
    static func stubbedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionTransport.sessionConfiguration()
        configuration.protocolClasses = [RedirectStub.self]
        return configuration
    }

    /// spec: "A redirect is not followed".
    @Test("a 302 to another host sends nothing to that host and fails as a network error without the token or cookie")
    func redirectNotFollowed() async throws {
        RedirectStub.log.reset()
        let transport = URLSessionTransport(session: URLSession(configuration: Self.stubbedConfiguration()))
        let client = SlackWebClient(transport: transport, clock: VirtualClock())

        let error = await #expect(throws: SlackError.self) {
            try await client.call("auth.test", parameters: [:], credential: credential)
        }

        #expect(RedirectStub.log.urls == [URL(string: "https://slack.com/api/auth.test")!])
        guard case let .network(description) = error else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
        #expect(description.contains("302"))
        let text = "\(try #require(error))"
        for secret in [credential.token, credential.cookie, SlackWebClient.formEncode(credential.cookie)] {
            #expect(!text.contains(secret), "the error contains a credential")
        }
    }

    /// Without the refusal, URLSession follows the stub's redirect. If this
    /// ever stops holding, `redirectNotFollowed` passes whether or not the
    /// transport refuses redirects, and needs another way to observe them.
    @Test("a plain session follows the stub's redirect, so the test above can tell refusing from following")
    func stubRedirectIsFollowedWithoutRefusal() async throws {
        RedirectStub.log.reset()
        let request = SlackWebClient(transport: RecordingTransport())
            .request(method: "auth.test", parameters: [:], credential: credential)

        _ = try await URLSession(configuration: Self.stubbedConfiguration()).data(for: request)

        #expect(RedirectStub.log.urls == [URL(string: "https://slack.com/api/auth.test")!,
                                          URL(string: "https://example.invalid/steal")!])
    }
}

/// Answers a request to slack.com with HTTP 302 to
/// `https://example.invalid/steal`, carrying the original method, headers and
/// body, and any other request with `{"ok":true}`. Records every URL it is
/// asked to load.
final class RedirectStub: URLProtocol {
    static let log = StubLog()
    static let target = URL(string: "https://example.invalid/steal")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.log.record(url)
        if url.host == "slack.com" {
            var redirected = request
            redirected.url = Self.target
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.target.absoluteString])!
            client.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // Reached by a refused redirect: the 302 is the answer.
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// The URLs `RedirectStub` was asked to load, in order.
final class StubLog: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [URL] = []

    var urls: [URL] { lock.withLock { loaded } }
    func record(_ url: URL) { lock.withLock { loaded.append(url) } }
    func reset() { lock.withLock { loaded = [] } }
}
