import Foundation
import SlackWebLib

/// Shared wording for tool results. Built only from fixed phrases and the
/// index's team ids, domains and names, never from a credential.
enum ToolText {
    /// Both ways to import a workspace (spec: slack-mcp-tools, "Workspace
    /// selection" and "Tool error results").
    static let importCommands = "slack-all auth import or slack-all auth import --from-desktop"

    static let noWorkspaceImported =
        "No Slack workspace is imported. Run \(importCommands) in a terminal to import one."

    /// `T01 alpha (Alpha)`: team id, domain, then name.
    static func label(_ workspace: SlackWorkspace) -> String {
        "\(workspace.teamID) \(workspace.domain) (\(workspace.name))"
    }

    /// Every workspace's label, comma separated.
    static func list(_ workspaces: [SlackWorkspace]) -> String {
        workspaces.map(label).joined(separator: ", ")
    }

    static func importAgain(_ workspace: SlackWorkspace) -> String {
        "Import workspace \(label(workspace)) again with \(importCommands)."
    }

    /// What a client error means for `workspace` (spec: slack-mcp-tools,
    /// "Tool error results"; design: Slack 錯誤分成五類). The error's own
    /// strings were scrubbed of the credential by the client.
    static func describe(_ error: SlackError, in workspace: SlackWorkspace) -> String {
        let name = label(workspace)
        switch error {
        case let .sessionInvalid(_, code):
            return "The Slack session for workspace \(name) is no longer valid (\(code)). \(importAgain(workspace))"
        case let .rateLimited(seconds):
            return "Slack is rate limiting workspace \(name) and the retries ran out; try again after \(seconds) s."
        case let .enterpriseRestricted(_, code):
            return "Workspace \(name) is restricted by Enterprise Grid (\(code)). Enterprise Grid can end automated "
                + "sessions, so use Slack's official MCP server for this workspace instead."
        case let .slackError(code):
            return "Slack returned an error for workspace \(name): \(code)."
        case let .network(description):
            return "Network error talking to Slack for workspace \(name): \(description)"
        }
    }

    /// The error's class, as `auth_status` reports it: the `SlackError`
    /// case name.
    static func className(_ error: SlackError) -> String {
        switch error {
        case .sessionInvalid: return "sessionInvalid"
        case .rateLimited: return "rateLimited"
        case .enterpriseRestricted: return "enterpriseRestricted"
        case .slackError: return "slackError"
        case .network: return "network"
        }
    }
}
