import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Session token request authentication".
@Suite("Session token request authentication")
struct RequestAuthenticationTests {
    let credential = SlackCredential(teamID: "T01", token: "xoxc-1", cookie: "abc%2F")

    @Test("auth.test carries the token in the body and the cookie in a header")
    func tokenInBodyCookieInHeader() throws {
        let request = SlackWebClient(transport: RecordingTransport())
            .request(method: "auth.test", parameters: [:], credential: credential)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://slack.com/api/auth.test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "d=abc%2F")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.split(separator: "&").contains("token=xoxc-1"))
        let url = try #require(request.url?.absoluteString)
        #expect(!url.contains("xoxc-1"))
        #expect(!url.contains("abc%2F"))
    }

    @Test("parameters are form-encoded after the token")
    func parametersAreFormEncoded() throws {
        let request = SlackWebClient(transport: RecordingTransport())
            .request(method: "chat.postMessage",
                     parameters: ["channel": "C01", "text": "a&b=c 收到"],
                     credential: credential)

        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        // Expected encodings written out by hand (application/x-www-form-urlencoded).
        #expect(body.split(separator: "&").contains("channel=C01"))
        #expect(body.split(separator: "&").contains("text=a%26b%3Dc%20%E6%94%B6%E5%88%B0"))
    }

    @Test("call sends the built request through the transport")
    func callUsesTransport() async throws {
        let transport = RecordingTransport()
        _ = try await SlackWebClient(transport: transport)
            .call("auth.test", parameters: [:], credential: credential)

        let sent = try #require(await transport.requests.first)
        #expect(sent.url?.absoluteString == "https://slack.com/api/auth.test")
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "d=abc%2F")
    }
}

/// Records every request and answers `{"ok":true}`.
actor RecordingTransportState {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

final class RecordingTransport: SlackTransport, @unchecked Sendable {
    private let state = RecordingTransportState()
    var requests: [URLRequest] { get async { await state.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await state.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"ok":true}"#.utf8), response)
    }
}
