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

/// Every textual form of a credential names the workspace and writes
/// `<redacted>` for both values (spec: slack-web-client, "No credential in
/// output"). `CustomReflectable` covers `dump()` and anything that walks the
/// value through `Mirror`, such as test-failure output.
extension SlackCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let redacted = "<redacted>"

    public var description: String {
        "SlackCredential(teamID: \(teamID), token: \(Self.redacted), cookie: \(Self.redacted))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self,
               children: ["teamID": teamID, "token": Self.redacted, "cookie": Self.redacted],
               displayStyle: .struct)
    }
}
