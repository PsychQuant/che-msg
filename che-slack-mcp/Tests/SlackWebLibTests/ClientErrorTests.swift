import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — "Slack error classification" observed through
/// `call`, and "No credential in output" for the errors `call` throws.
@Suite("call classifies failures")
struct ClientErrorTests {
    static let token = "xoxc-9999-secret-token"
    static let cookie = "xoxd-secret%2Bcookie"

    static func credential(_ team: String = "T01") -> SlackCredential {
        SlackCredential(teamID: team, token: token, cookie: cookie)
    }

    /// Calls `auth.test` once and returns the thrown `SlackError`, or nil
    /// when the call succeeded.
    static func failure(of step: ScriptedStep, team: String = "T01") async -> SlackError? {
        let client = SlackWebClient(transport: RecordingTransport([step]))
        do {
            _ = try await client.call("auth.test", parameters: [:], credential: credential(team))
            return nil
        } catch let error as SlackError {
            return error
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
            return nil
        }
    }

    @Test("a revoked session in workspace myteam throws sessionInvalid naming myteam")
    func revokedSessionNamesWorkspace() async throws {
        let error = try #require(await Self.failure(of: .slackError("invalid_auth"), team: "myteam"))

        #expect(error == .sessionInvalid(workspace: "myteam", error: "invalid_auth"))
        #expect(error.description.contains("myteam"))
    }

    @Test("spec classification table, rows answered on the first attempt", arguments: [
        (ScriptedStep.slackError("token_revoked"), SlackError.sessionInvalid(workspace: "T01", error: "token_revoked")),
        (.slackError("enterprise_is_restricted"), .enterpriseRestricted(workspace: "T01", error: "enterprise_is_restricted")),
        (.slackError("channel_not_found"), .slackError("channel_not_found")),
        (.fail(URLError(.timedOut)), .network(URLError(.timedOut).localizedDescription)),
    ])
    func classificationTable(step: ScriptedStep, expected: SlackError) async {
        #expect(await Self.failure(of: step) == expected)
    }

    @Test("an enterprise restriction names the workspace and Slack's error string")
    func enterpriseNamesWorkspace() async throws {
        let error = try #require(await Self.failure(of: .slackError("team_is_restricted"), team: "TENT01"))

        #expect(error.description.contains("TENT01"))
        #expect(error.description.contains("team_is_restricted"))
    }

    @Test("a successful call returns the raw body")
    func successReturnsBody() async throws {
        let body = #"{"ok":true,"team_id":"T01"}"#
        let client = SlackWebClient(transport: RecordingTransport([.respond(status: 200, body: body)]))

        let data = try await client.call("auth.test", parameters: [:], credential: Self.credential())

        #expect(String(decoding: data, as: UTF8.self) == body)
    }

    @Test("cancellation from the transport propagates as CancellationError")
    func cancellationPropagates() async {
        let client = SlackWebClient(transport: RecordingTransport([.fail(CancellationError())]))

        await #expect(throws: CancellationError.self) {
            try await client.call("auth.test", parameters: [:], credential: Self.credential())
        }
    }

    @Test("credentials echoed by the transport or by Slack are redacted from the thrown error", arguments: [
        ScriptedStep.fail(EchoingTransportError(text: "POST body token=\(token) Cookie: d=\(cookie)")),
        .slackError("bad_token_\(token)_\(cookie)"),
    ])
    func echoedCredentialsAreRedacted(step: ScriptedStep) async throws {
        let error = try #require(await Self.failure(of: step))

        for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
            #expect(text.contains("<redacted>"))
            #expect(!text.contains(Self.token))
            #expect(!text.contains(Self.cookie))
        }
    }
}
