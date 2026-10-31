import Foundation

/// Where che-slack-mcp keeps its credentials in the Keychain (spec:
/// slack-credentials, "Keychain credential layout"). Every item uses the
/// account `che-slack-mcp`; the service names one item:
///
/// - `SLACK_WORKSPACES`: the index, a JSON array of `SlackWorkspace` objects
///   stored as the standard base64 (with padding) of its UTF-8, so that a
///   name in any script passes the write path's character check. It holds
///   no credential.
/// - `SLACK_TOKEN_<team_id>`: that workspace's `xoxc` token.
/// - `SLACK_COOKIE_<team_id>`: that workspace's `d` cookie value.
///
/// Each workspace keeps its own cookie even though `d` can be shared, so a
/// later import from another browser cannot overwrite an earlier one.
public enum SlackKeychain {
    public static let account = "che-slack-mcp"
    public static let workspacesService = "SLACK_WORKSPACES"

    public static func tokenService(teamID: String) -> String { "SLACK_TOKEN_\(teamID)" }
    public static func cookieService(teamID: String) -> String { "SLACK_COOKIE_\(teamID)" }

    /// True when `value` is non-empty and every character is one the write
    /// path accepts (`A-Z a-z 0-9 - _ . % + / =`).
    public static func acceptsValue(_ value: String) -> Bool {
        (try? KeychainWritePolicy.check(service: workspacesService, value: value)) != nil
    }
}

/// One entry of the `SLACK_WORKSPACES` index. It names a workspace and its
/// signed-in user; the credential lives in the workspace's own two items.
public struct SlackWorkspace: Codable, Equatable, Sendable {
    public let teamID: String
    public let domain: String
    public let name: String
    public let userID: String

    public init(teamID: String, domain: String, name: String, userID: String) {
        self.teamID = teamID
        self.domain = domain
        self.name = name
        self.userID = userID
    }

    /// True when `query` equals this workspace's team id or domain, ignoring
    /// case. No prefix or substring match.
    public func matches(_ query: String) -> Bool {
        let wanted = query.lowercased()
        return !wanted.isEmpty && (wanted == teamID.lowercased() || wanted == domain.lowercased())
    }

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case domain
        case name
        case userID = "user_id"
    }
}
