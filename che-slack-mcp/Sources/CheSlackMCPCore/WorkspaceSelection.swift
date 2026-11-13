import Foundation
import MCP
import SlackWebLib

/// The `workspace` argument as the caller gave it.
enum WorkspaceArgument: Equatable, Sendable {
    case omitted
    case query(String)
}

/// One workspace chosen for a tool call, with its credential read from the
/// Keychain for this call only.
struct ResolvedWorkspace: Sendable {
    let workspace: SlackWorkspace
    let credential: SlackCredential
}

/// Picks the workspace a tool call acts on (spec: slack-mcp-tools,
/// "Workspace selection"). Every tool except `list_workspaces` goes through
/// it before calling Slack, so a refused selection never reaches Slack.
///
/// Rules, in order:
/// 1. `workspace` absent or JSON `null` → omitted. Any other non-string
///    value is refused, naming the argument, before the Keychain is read.
/// 2. The index `SLACK_WORKSPACES` is read; a read failure is refused with
///    the Keychain's own message, never taken for "nothing imported".
/// 3. Nothing imported → refused, naming both import commands.
/// 4. Omitted: used when exactly one is imported; otherwise refused, listing
///    every imported workspace. Never a silent pick.
/// 5. A string is compared with each team id and domain, ignoring case and
///    whole (`SlackWorkspace.matches`). No match, an empty string, or more
///    than one match (a domain equal to another workspace's team id) is
///    refused, listing every imported workspace. The query itself is never
///    repeated in a message.
struct WorkspaceResolver: Sendable {
    static let argumentName = "workspace"

    let store: SlackCredentialStore

    /// The selected workspace and its credential, or the failure to return
    /// instead. Reads the Keychain on every call.
    func resolve(_ arguments: [String: Value]) async -> Result<ResolvedWorkspace, ToolFailure> {
        do {
            let argument = try Self.argument(in: arguments)
            let workspace = try Self.select(argument, among: try await workspaces())
            return .success(ResolvedWorkspace(workspace: workspace, credential: try await credential(for: workspace)))
        } catch {
            return .failure(error)
        }
    }

    /// The imported workspaces; a broken or unreadable index is a failure.
    func workspaces() async throws(ToolFailure) -> [SlackWorkspace] {
        do {
            return try await store.workspaces()
        } catch {
            throw ToolFailure(Self.describe(error))
        }
    }

    /// `workspace`'s credential, read now.
    func credential(for workspace: SlackWorkspace) async throws(ToolFailure) -> SlackCredential {
        do {
            return try await store.credential(for: workspace.teamID)
        } catch SlackCredentialError.absent(let service) {
            throw ToolFailure("\(SlackCredentialError.absent(service: service).description) \(ToolText.importAgain(workspace))")
        } catch {
            throw ToolFailure(Self.describe(error))
        }
    }

    static func argument(in arguments: [String: Value]) throws(ToolFailure) -> WorkspaceArgument {
        switch arguments[argumentName] {
        case nil, .null?:
            return .omitted
        case let .string(query)?:
            return .query(query)
        default:
            throw ToolFailure("\(argumentName) must be a string: the team id or domain of an imported workspace.")
        }
    }

    static func select(_ argument: WorkspaceArgument, among workspaces: [SlackWorkspace]) throws(ToolFailure) -> SlackWorkspace {
        guard !workspaces.isEmpty else { throw ToolFailure(ToolText.noWorkspaceImported) }
        let imported = "Imported: \(ToolText.list(workspaces))."
        switch argument {
        case .omitted:
            guard workspaces.count == 1 else {
                throw ToolFailure("\(workspaces.count) Slack workspaces are imported, so \(argumentName) is required: "
                                  + "pass the team id or domain of one of them. \(imported)")
            }
            return workspaces[0]
        case .query(let query):
            guard !query.isEmpty else {
                throw ToolFailure("\(argumentName) is empty: pass the team id or domain of an imported workspace. \(imported)")
            }
            let matches = workspaces.filter { $0.matches(query) }
            guard matches.count == 1 else {
                throw ToolFailure(matches.isEmpty
                    ? "No imported Slack workspace has that team id or domain. \(imported)"
                    : "That value is the team id or domain of more than one imported workspace, so none was chosen; "
                      + "pass a team id. \(imported)")
            }
            return matches[0]
        }
    }

    /// A Keychain failure's own message. `SlackCredentialError` never holds
    /// an item's value; anything else is described by its type only.
    private static func describe(_ error: any Error) -> String {
        if let error = error as? SlackCredentialError { return error.description }
        return "Reading the Keychain failed (\(type(of: error)))."
    }
}
