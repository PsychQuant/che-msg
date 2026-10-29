import Foundation

/// What `auth.test` says about a credential: the workspace and the user it
/// signs in as. It holds no credential. Used by `slack-all auth import` and
/// `auth status` to verify a session (spec: slack-credentials, "Clipboard
/// import").
public struct SlackAuthTest: Equatable, Sendable, Decodable {
    public let teamID: String
    public let userID: String
    /// The workspace's name, as Slack reports it.
    public let team: String?
    /// The workspace's URL, e.g. `https://alpha.slack.com/`.
    public let url: String?

    public init(teamID: String, userID: String, team: String? = nil, url: String? = nil) {
        self.teamID = teamID
        self.userID = userID
        self.team = team
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case userID = "user_id"
        case team
        case url
    }
}

extension SlackWebClient {
    /// Calls `auth.test` with `credential`.
    ///
    /// - Throws: the call's `SlackError`, or
    ///   `slackError("unexpected_response")` when an `ok: true` answer has
    ///   no string `team_id` or `user_id`.
    public func authTest(credential: SlackCredential) async throws -> SlackAuthTest {
        let data = try await call("auth.test", parameters: [:], credential: credential)
        // The decoding error could quote the body; a fixed code cannot.
        guard let answer = try? JSONDecoder().decode(SlackAuthTest.self, from: data) else {
            throw SlackError.slackError("unexpected_response")
        }
        return answer
    }
}
