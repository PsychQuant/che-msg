import Foundation

/// The five ways a Slack call fails (spec: slack-web-client, "Slack error
/// classification"). No case ever holds a token or a cookie: workspaces are
/// named by team id, and text that comes from outside (Slack's error string,
/// the transport's description) is scrubbed of both values before it is
/// stored here.
public enum SlackError: Error, Equatable, Sendable {
    /// `invalid_auth`, `not_authed`, `token_revoked` or `account_inactive`.
    case sessionInvalid(workspace: String, error: String)
    /// HTTP 429 or `ratelimited`, after the client's retries ran out. Carries
    /// the wait the last answer asked for.
    case rateLimited(retryAfterSeconds: Int)
    /// An error beginning with `enterprise_`, or `team_is_restricted`.
    case enterpriseRestricted(workspace: String, error: String)
    /// Any other failure Slack reported, carrying Slack's error string
    /// verbatim, or one of the client's own codes listed on
    /// `SlackResponseClassifier`.
    case slackError(String)
    /// The transport failed; carries its description.
    case network(String)
}

extension SlackError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .sessionInvalid(workspace, error):
            return "The Slack session for workspace \(workspace) is no longer valid (\(error))."
        case let .rateLimited(seconds):
            return "Slack is rate limiting this workspace; retry after \(seconds) s."
        case let .enterpriseRestricted(workspace, error):
            return "Workspace \(workspace) is restricted by Enterprise Grid (\(error))."
        case let .slackError(error):
            return "Slack returned an error: \(error)."
        case let .network(description):
            return "Network error talking to Slack: \(description)"
        }
    }

    public var errorDescription: String? { description }
}

extension SlackError {
    /// A copy with every occurrence of the credential's token and cookie,
    /// raw or form-encoded, replaced by `<redacted>` in the strings that came
    /// from outside the client.
    func redacting(_ credential: SlackCredential) -> SlackError {
        let secrets = Set([credential.token, credential.cookie,
                           SlackWebClient.formEncode(credential.token), SlackWebClient.formEncode(credential.cookie)])
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        func scrub(_ text: String) -> String {
            secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: SlackCredential.redacted) }
        }
        switch self {
        case let .sessionInvalid(workspace, error): return .sessionInvalid(workspace: workspace, error: scrub(error))
        case .rateLimited: return self
        case let .enterpriseRestricted(workspace, error): return .enterpriseRestricted(workspace: workspace, error: scrub(error))
        case let .slackError(error): return .slackError(scrub(error))
        case let .network(description): return .network(scrub(description))
        }
    }
}

/// Maps one HTTP answer to the call's result. Pure, so the whole table is
/// testable without a transport.
///
/// Rules, in order:
/// 1. HTTP 429 → `rateLimited`.
/// 2. A JSON object with `"ok": false` → classified by its `error` string,
///    whatever the HTTP status (Slack's own code is more specific than the
///    status). `ok:false` without a string `error` → `slackError("unknown_error")`.
/// 3. Any status other than 200 → `slackError("http_<status>")`.
/// 4. A 200 whose body is not a JSON object with a boolean `ok` (empty, HTML,
///    an array, `"ok": "true"`, `"ok": 1`, a non-string `error`) →
///    `slackError("invalid_json")`.
/// 5. HTTP 200 with `"ok": true` → success, body unchanged.
///
/// One more client code comes from a method wrapper rather than this table:
/// `authTest` throws `slackError("unexpected_response")` for an `ok: true`
/// answer without the fields it needs.
enum SlackResponseClassifier {
    static let sessionErrors: Set<String> = ["invalid_auth", "not_authed", "token_revoked", "account_inactive"]

    private struct Envelope: Decodable {
        let ok: Bool
        let error: String?
    }

    static func classify(status: Int, retryAfter: String?, body: Data, workspace: String) -> Result<Data, SlackError> {
        if status == 429 {
            return .failure(.rateLimited(retryAfterSeconds: retryAfterSeconds(retryAfter)))
        }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        if let envelope, !envelope.ok {
            guard let error = envelope.error else { return .failure(.slackError("unknown_error")) }
            return .failure(classify(error: error, retryAfter: retryAfter, workspace: workspace))
        }
        guard status == 200 else { return .failure(.slackError("http_\(status)")) }
        guard envelope != nil else { return .failure(.slackError("invalid_json")) }
        return .success(body)
    }

    static func classify(error: String, retryAfter: String?, workspace: String) -> SlackError {
        if sessionErrors.contains(error) { return .sessionInvalid(workspace: workspace, error: error) }
        if error == "ratelimited" { return .rateLimited(retryAfterSeconds: retryAfterSeconds(retryAfter)) }
        if error.hasPrefix("enterprise_") || error == "team_is_restricted" {
            return .enterpriseRestricted(workspace: workspace, error: error)
        }
        return .slackError(error)
    }

    /// The `Retry-After` value in whole seconds, or 1 when the header is
    /// absent or not a non-negative integer (an HTTP date, a sign, a decimal
    /// point, or digits too large for `Int`). Surrounding whitespace is not
    /// part of an HTTP field value, so it is ignored.
    static func retryAfterSeconds(_ header: String?) -> Int {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
              value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let seconds = Int(value)
        else { return 1 }
        return seconds
    }
}
