import Foundation
import Testing
@testable import SlackWebLib

/// `SlackWebClient.authTest`: the `auth.test` call that `slack-all auth
/// import` and `auth status` use to verify a session.
@Suite("auth.test")
struct AuthTestCallTests {
    let credential = SlackCredential(teamID: "T01", token: "xoxc-fake-1", cookie: "xoxd-fake%2F1")

    @Test("an ok answer gives its team id, user id, team name and url")
    func decodesAnswer() async throws {
        let transport = RecordingTransport([.respond(status: 200, body: #"""
            {"ok":true,"url":"https://alpha.slack.com/","team":"Alpha","user":"me","team_id":"T01","user_id":"U01"}
            """#)])

        let answer = try await SlackWebClient(transport: transport).authTest(credential: credential)

        #expect(answer == SlackAuthTest(teamID: "T01", userID: "U01", team: "Alpha", url: "https://alpha.slack.com/"))
        let sent = try #require(await transport.requests.first)
        #expect(sent.url?.absoluteString == "https://slack.com/api/auth.test")
    }

    @Test("an ok answer without a string team_id or user_id throws slackError(unexpected_response)", arguments: [
        #"{"ok":true}"#,
        #"{"ok":true,"team_id":"T01"}"#,
        #"{"ok":true,"team_id":1,"user_id":"U01"}"#,
        #"{"ok":true,"team_id":"T01","user_id":null}"#,
    ])
    func missingFieldsThrow(body: String) async throws {
        let transport = RecordingTransport([.respond(status: 200, body: body)])

        await #expect(throws: SlackError.slackError("unexpected_response")) {
            _ = try await SlackWebClient(transport: transport).authTest(credential: credential)
        }
    }

    @Test("an invalid_auth answer throws sessionInvalid for the workspace")
    func invalidAuthThrows() async throws {
        let transport = RecordingTransport([.slackError("invalid_auth")])

        await #expect(throws: SlackError.sessionInvalid(workspace: "T01", error: "invalid_auth")) {
            _ = try await SlackWebClient(transport: transport).authTest(credential: credential)
        }
    }
}
