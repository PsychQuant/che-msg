import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Slack error classification", tested
/// on the pure classifier. The same table through `call` is in
/// `ClientErrorTests`.
@Suite("Slack error classification")
struct ErrorClassificationTests {
    static func classify(_ status: Int, _ body: String, retryAfter: String? = nil) -> Result<Data, SlackError> {
        SlackResponseClassifier.classify(status: status, retryAfter: retryAfter, body: Data(body.utf8), workspace: "T01")
    }

    @Test("ok:false error strings map to their class", arguments: [
        // spec: the four session errors
        ("invalid_auth", SlackError.sessionInvalid(workspace: "T01", error: "invalid_auth")),
        ("not_authed", .sessionInvalid(workspace: "T01", error: "not_authed")),
        ("token_revoked", .sessionInvalid(workspace: "T01", error: "token_revoked")),
        ("account_inactive", .sessionInvalid(workspace: "T01", error: "account_inactive")),
        // spec: `ratelimited`; no Retry-After header -> 1 second
        ("ratelimited", .rateLimited(retryAfterSeconds: 1)),
        // spec: begins with `enterprise_`, or equals `team_is_restricted`
        ("enterprise_is_restricted", .enterpriseRestricted(workspace: "T01", error: "enterprise_is_restricted")),
        ("enterprise_", .enterpriseRestricted(workspace: "T01", error: "enterprise_")),
        ("team_is_restricted", .enterpriseRestricted(workspace: "T01", error: "team_is_restricted")),
        // everything else carries Slack's string verbatim, including near misses
        ("channel_not_found", .slackError("channel_not_found")),
        ("not_enterprise_admin", .slackError("not_enterprise_admin")),
        ("team_is_restricted_now", .slackError("team_is_restricted_now")),
        ("invalid_auth_x", .slackError("invalid_auth_x")),
        ("Invalid_Auth", .slackError("Invalid_Auth")),
    ])
    func errorStrings(error: String, expected: SlackError) {
        #expect(Self.classify(200, #"{"ok":false,"error":"\#(error)"}"#) == .failure(expected))
    }

    @Test("HTTP 200 with ok:true succeeds and returns the body unchanged")
    func okTrue() {
        let body = #"{"ok":true,"user_id":"U1"}"#
        #expect(Self.classify(200, body) == .success(Data(body.utf8)))
    }

    @Test("status and body shapes", arguments: [
        // spec: HTTP 429 is rateLimited whatever the body says
        (429, "", "5", SlackError.rateLimited(retryAfterSeconds: 5)),
        (429, #"{"ok":true}"#, nil, .rateLimited(retryAfterSeconds: 1)),
        // `ratelimited` in a 200 body uses the header when present
        (200, #"{"ok":false,"error":"ratelimited"}"#, "7", .rateLimited(retryAfterSeconds: 7)),
        // Slack's own error string wins over a non-200 status
        (401, #"{"ok":false,"error":"invalid_auth"}"#, nil, .sessionInvalid(workspace: "T01", error: "invalid_auth")),
        // chosen: other non-200 answers -> slackError("http_<status>")
        (500, "<html>Internal Server Error</html>", nil, .slackError("http_500")),
        (503, #"{"ok":true}"#, nil, .slackError("http_503")),
        // chosen: a 200 body that is not {"ok": <bool>} -> slackError("invalid_json")
        (200, "", nil, .slackError("invalid_json")),
        (200, "<html>sign in</html>", nil, .slackError("invalid_json")),
        (200, "[]", nil, .slackError("invalid_json")),
        (200, "{}", nil, .slackError("invalid_json")),
        (200, #"{"ok":"true"}"#, nil, .slackError("invalid_json")),
        (200, #"{"ok":1}"#, nil, .slackError("invalid_json")),
        (200, #"{"ok":false,"error":5}"#, nil, .slackError("invalid_json")),
        // chosen: ok:false without an error string -> slackError("unknown_error")
        (200, #"{"ok":false}"#, nil, .slackError("unknown_error")),
    ] as [(Int, String, String?, SlackError)])
    func shapes(status: Int, body: String, retryAfter: String?, expected: SlackError) {
        #expect(Self.classify(status, body, retryAfter: retryAfter) == .failure(expected))
    }

    @Test("Retry-After is used only when it is a non-negative integer", arguments: [
        (nil, 1), ("", 1), ("5", 5), ("0", 0), (" 7 ", 7),
        ("-1", 1), ("2.5", 1), ("+3", 1), ("abc", 1), ("1e3", 1),
        ("Wed, 21 Oct 2015 07:28:00 GMT", 1),
        // chosen: digits that overflow Int are treated as unusable
        ("99999999999999999999", 1),
    ] as [(String?, Int)])
    func retryAfterParsing(header: String?, seconds: Int) {
        #expect(SlackResponseClassifier.retryAfterSeconds(header) == seconds)
    }
}
