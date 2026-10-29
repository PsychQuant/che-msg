import Foundation

/// One workspace's browser session credential: an `xoxc` token and the `d`
/// cookie value. Either value alone is equivalent to the user's signed-in
/// session, so it never belongs in a URL, a log line or a tool result.
public struct SlackCredential: Sendable, Equatable {
    public let teamID: String
    public let token: String
    public let cookie: String

    public init(teamID: String, token: String, cookie: String) {
        self.teamID = teamID
        self.token = token
        self.cookie = cookie
    }
}
