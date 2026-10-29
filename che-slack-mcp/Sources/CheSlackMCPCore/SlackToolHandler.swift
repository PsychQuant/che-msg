import Foundation
import MCP
import SlackWebLib

/// Answers `tools/list` and `tools/call` for che-slack-mcp. Holds no
/// credential: every call reads the Keychain again through `store`, and
/// `tools` reads nothing.
struct SlackToolHandler: Sendable {
    let store: SlackCredentialStore
    let client: SlackWebClient

    var resolver: WorkspaceResolver { WorkspaceResolver(store: store) }

    /// Every tool, in the order `tools/list` returns them.
    static let tools: [Tool] = [
        tool("list_workspaces",
             description: """
             List the imported Slack workspaces with their team id, domain and name, without calling Slack. \
             Pass a team id or domain as `workspace` to the other tools. Workspaces are imported in a terminal \
             with `slack-all auth import` or `slack-all auth import --from-desktop`.
             """,
             properties: [:]),
        tool("auth_status",
             description: """
             Check Slack sessions with auth.test: the workspace named by `workspace`, or every imported \
             workspace when it is omitted. Reports per workspace whether the session is valid and, if not, \
             error_class (sessionInvalid, rateLimited, enterpriseRestricted, slackError, network, \
             credentialUnavailable or teamMismatch) and a message saying what to do. One invalid session is \
             reported in the list, not as an error result.
             """,
             properties: workspaceProperty),
    ] + readTools

    /// The optional `workspace` argument every tool except
    /// `list_workspaces` takes (spec: slack-mcp-tools, "Workspace selection").
    static let workspaceProperty: [String: Value] = [
        WorkspaceResolver.argumentName: prop("string", """
            Team id (e.g. T0123ABCD) or domain (e.g. myteam for myteam.slack.com) of an imported workspace, \
            matched whole and ignoring case. May be omitted when exactly one workspace is imported.
            """),
    ]

    /// Runs one tool. Never throws: every failure is a result with
    /// `isError: true`, never a JSON-RPC protocol error.
    func callTool(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let arguments = arguments ?? [:]
        switch name {
        case "list_workspaces": return await listWorkspaces()
        case "auth_status": return await authStatus(arguments)
        case "list_conversations": return await listConversations(arguments)
        case "get_conversation_history": return await conversationHistory(arguments)
        case "get_thread_replies": return await threadReplies(arguments)
        case "get_user": return await user(arguments)
        case "search_messages": return await searchMessages(arguments)
        default: return ToolResult.error("Unknown tool: \(name)")
        }
    }

    /// Selects the workspace from `arguments`, then runs `body` with it and
    /// its credential. Every tool that calls Slack runs inside this, so
    /// (spec: slack-mcp-tools, "Tool error results"):
    /// - a refused selection returns before `body`, so Slack is not called;
    /// - a `SlackError` becomes an error result in its class's wording;
    /// - a `ToolFailure` from `body` is returned as its own message;
    /// - any other error is described by its type only, since its text could
    ///   quote a Slack answer.
    /// It never throws, so no failure becomes a JSON-RPC protocol error.
    func withWorkspace(_ arguments: [String: Value],
                       _ body: (ResolvedWorkspace) async throws -> CallTool.Result) async -> CallTool.Result {
        let selection: ResolvedWorkspace
        switch await resolver.resolve(arguments) {
        case .success(let resolved): selection = resolved
        case .failure(let failure): return failure.result
        }
        do {
            return try await body(selection)
        } catch let error as SlackError {
            return ToolResult.error(ToolText.describe(error, in: selection.workspace))
        } catch let failure as ToolFailure {
            return failure.result
        } catch is CancellationError {
            return ToolResult.error("The call for workspace \(ToolText.label(selection.workspace)) was cancelled.")
        } catch {
            return ToolResult.error("The call for workspace \(ToolText.label(selection.workspace)) failed (\(type(of: error))).")
        }
    }

    // MARK: - list_workspaces

    private struct ListedWorkspace: Encodable {
        let team_id: String
        let domain: String
        let name: String
    }

    private struct WorkspaceList: Encodable {
        let workspaces: [ListedWorkspace]
        /// Set only when nothing is imported.
        let hint: String?
    }

    /// Reads only the index; the user id stays out, as the spec lists team
    /// id, domain and name.
    private func listWorkspaces() async -> CallTool.Result {
        let workspaces: [SlackWorkspace]
        do {
            workspaces = try await resolver.workspaces()
        } catch {
            return error.result
        }
        return ToolResult.json(WorkspaceList(
            workspaces: workspaces.map { ListedWorkspace(team_id: $0.teamID, domain: $0.domain, name: $0.name) },
            hint: workspaces.isEmpty ? ToolText.noWorkspaceImported : nil))
    }

    // MARK: - auth_status

    private struct StatusEntry: Encodable {
        let team_id: String
        let domain: String
        let name: String
        let valid: Bool
        let error_class: String?
        let message: String?
    }

    private struct StatusReport: Encodable {
        let workspaces: [StatusEntry]
    }

    /// Omitted `workspace` means every imported workspace, so two or more
    /// imported is not ambiguous here; the other selection rules apply as
    /// for every tool. Workspaces are checked one after another.
    private func authStatus(_ arguments: [String: Value]) async -> CallTool.Result {
        let targets: [SlackWorkspace]
        do throws(ToolFailure) {
            let argument = try WorkspaceResolver.argument(in: arguments)
            let imported = try await resolver.workspaces()
            if argument == .omitted {
                guard !imported.isEmpty else { throw ToolFailure(ToolText.noWorkspaceImported) }
                targets = imported
            } else {
                targets = [try WorkspaceResolver.select(argument, among: imported)]
            }
        } catch {
            return error.result
        }
        var entries: [StatusEntry] = []
        for workspace in targets {
            guard let entry = await check(workspace) else {
                return ToolResult.error("auth_status was cancelled.")
            }
            entries.append(entry)
        }
        return ToolResult.json(StatusReport(workspaces: entries))
    }

    /// One workspace's session, or nil when the call was cancelled. A
    /// credential that cannot be read is reported for its workspace as
    /// `credentialUnavailable` rather than failing the whole report.
    private func check(_ workspace: SlackWorkspace) async -> StatusEntry? {
        func invalid(_ errorClass: String, _ message: String) -> StatusEntry {
            StatusEntry(team_id: workspace.teamID, domain: workspace.domain, name: workspace.name,
                        valid: false, error_class: errorClass, message: message)
        }
        do {
            let credential = try await resolver.credential(for: workspace)
            let answer = try await client.authTest(credential: credential)
            guard answer.teamID == workspace.teamID else {
                return invalid("teamMismatch",
                               "auth.test with the credential stored for workspace \(ToolText.label(workspace)) "
                               + "answered for team \(answer.teamID). \(ToolText.importAgain(workspace))")
            }
            return StatusEntry(team_id: workspace.teamID, domain: workspace.domain, name: workspace.name,
                               valid: true, error_class: nil, message: nil)
        } catch let failure as ToolFailure {
            return invalid("credentialUnavailable", failure.message)
        } catch let error as SlackError {
            return invalid(ToolText.className(error), ToolText.describe(error, in: workspace))
        } catch {
            // `authTest` throws only `SlackError` and `CancellationError`.
            return nil
        }
    }

    // MARK: - Schema helpers

    static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    static func tool(_ name: String, description: String, properties: [String: Value],
                             required: [String] = []) -> Tool {
        Tool(name: name, description: description, inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ]))
    }
}
