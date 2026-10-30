import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Session token request
/// authentication": the production transport keeps no HTTP state from
/// Slack's answers. `URLSession.shared` would store a `Set-Cookie` in
/// `~/Library/HTTPStorages/<executable>.binarycookies` and send it with every
/// later request, to any workspace. Only the configuration and the request
/// are checked: a `URLProtocol` stub's `Set-Cookie` is not stored even by a
/// session with cookie storage (tried while writing these tests), so
/// sending two calls through a stub passes with or without the fix.
@Suite("Transport keeps no cookies")
struct TransportCookieTests {
    let credential = SlackCredential(teamID: "T01", token: "xoxc-1", cookie: "abc%2F")

    @Test("the session has no cookie storage and no response cache")
    func sessionKeepsNoState() {
        let configuration = URLSessionTransport.sessionConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("a built request does not handle cookies")
    func requestDoesNotHandleCookies() {
        let request = SlackWebClient(transport: RecordingTransport())
            .request(method: "auth.test", parameters: [:], credential: credential)
        #expect(request.httpShouldHandleCookies == false)
    }
}
