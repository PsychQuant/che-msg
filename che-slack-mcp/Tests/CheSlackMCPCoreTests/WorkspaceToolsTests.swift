import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// One workspace in `list_workspaces`.
struct ListedWorkspace: Decodable, Equatable {
    let team_id: String
    let domain: String
    let name: String
}

struct WorkspaceList: Decodable, Equatable {
    let workspaces: [ListedWorkspace]
    let hint: String?
}

/// One workspace in `auth_status`.
struct StatusEntry: Decodable, Equatable {
    let team_id: String
    let domain: String
    let name: String
    let valid: Bool
    let error_class: String?
    let message: String?
}

struct StatusReport: Decodable, Equatable {
    let workspaces: [StatusEntry]
}

func decode<T: Decodable>(_ type: T.Type, _ result: CallTool.Result) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(text(result).utf8))
}

/// spec: slack-mcp-tools, "Workspace and session tools": `list_workspaces`.
@Suite("list_workspaces")
struct ListWorkspacesTests {
    @Test("returns each imported workspace's team id, domain and name, reading only the index and calling no Slack method")
    func listsWorkspaces() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
        let transport = TokenTransport()

        let result = await makeHandler(keychain, transport).callTool(name: "list_workspaces", arguments: [:])

        #expect(result.isError == false)
        #expect(try decode(WorkspaceList.self, result) == WorkspaceList(workspaces: [
            ListedWorkspace(team_id: "T01", domain: "alpha", name: "Alpha"),
            ListedWorkspace(team_id: "T02", domain: "beta", name: "Beta"),
        ], hint: nil))
        #expect(transport.requests.isEmpty)
        #expect(keychain.reads == ["SLACK_WORKSPACES"])
        #expect(keychain.changes.isEmpty)
        expectNoSecrets(result)
    }

    @Test("with nothing imported, returns an empty list and a hint naming both import commands, not an error")
    func nothingImported() async throws {
        let keychain = MemoryKeychain()

        let result = await makeHandler(keychain).callTool(name: "list_workspaces", arguments: nil)

        #expect(result.isError == false)
        let list = try decode(WorkspaceList.self, result)
        #expect(list.workspaces.isEmpty)
        #expect(list.hint?.contains("slack-all auth import or slack-all auth import --from-desktop") == true)
        expectNoSecrets(result)
    }

    @Test("an index that cannot be read is an error result naming SLACK_WORKSPACES")
    func unreadableIndex() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])
        keychain.force("SLACK_WORKSPACES", .found("not base64!"))

        let result = await makeHandler(keychain).callTool(name: "list_workspaces", arguments: [:])

        expectError(result, containing: ["SLACK_WORKSPACES"])
    }
}

/// spec: slack-mcp-tools, "Workspace and session tools": `auth_status`.
@Suite("auth_status")
struct AuthStatusToolTests {
    let keychain: MemoryKeychain

    init() async throws {
        keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
    }

    static let alphaValid = StatusEntry(team_id: "T01", domain: "alpha", name: "Alpha", valid: true,
                                        error_class: nil, message: nil)

    /// spec: "Expired session is reported per workspace".
    @Test("without workspace, alpha valid and beta invalid_auth are reported per workspace, and the result is not an error")
    func expiredSessionPerWorkspace() async throws {
        let transport = TokenTransport([
            Fake.alphaToken: .body(Fake.authTestOK(team: "T01", user: "U01")),
            Fake.betaToken: .body(Fake.slackError("invalid_auth")),
        ])

        let result = await makeHandler(keychain, transport).callTool(name: "auth_status", arguments: [:])

        #expect(result.isError == false)
        let report = try decode(StatusReport.self, result)
        #expect(report.workspaces.count == 2)
        #expect(report.workspaces.first == Self.alphaValid)
        let beta = try #require(report.workspaces.last)
        #expect(beta.team_id == "T02" && beta.domain == "beta" && !beta.valid)
        #expect(beta.error_class == "sessionInvalid")
        #expect(beta.message?.contains("slack-all auth import or slack-all auth import --from-desktop") == true)
        #expect(transport.methods == ["auth.test", "auth.test"])
        #expect(transport.tokens == [Fake.alphaToken, Fake.betaToken])
        expectNoSecrets(result)
    }

    @Test("with workspace, only the selected workspace is checked", arguments: ["BETA", "t02"])
    func selectedOnly(query: String) async throws {
        let transport = TokenTransport([Fake.betaToken: .body(Fake.authTestOK(team: "T02", user: "U02"))])

        let result = await makeHandler(keychain, transport).callTool(name: "auth_status",
                                                                     arguments: ["workspace": .string(query)])

        #expect(result.isError == false)
        #expect(try decode(StatusReport.self, result).workspaces ==
                [StatusEntry(team_id: "T02", domain: "beta", name: "Beta", valid: true, error_class: nil, message: nil)])
        #expect(transport.tokens == [Fake.betaToken])
        expectNoSecrets(result)
    }

    @Test("each client error class is reported by its name", arguments: ToolErrorResultTests.failures)
    func errorClasses(row: FailureRow) async throws {
        let transport = TokenTransport([Fake.betaToken: row.answer])

        let result = await makeHandler(keychain, transport).callTool(name: "auth_status",
                                                                     arguments: ["workspace": .string("beta")])

        #expect(result.isError == false)
        let entry = try #require(try decode(StatusReport.self, result).workspaces.first)
        #expect(!entry.valid)
        #expect(entry.error_class == row.name)
        expectNoSecrets(result)
    }

    @Test("with nothing imported, auth_status is an error result naming both import commands and calls nothing")
    func nothingImported() async throws {
        let transport = TokenTransport()

        let result = await makeHandler(MemoryKeychain(), transport).callTool(name: "auth_status", arguments: [:])

        expectError(result, containing: ["slack-all auth import", "slack-all auth import --from-desktop"])
        #expect(transport.requests.isEmpty)
    }

    @Test("a workspace that matches nothing is an error result listing both, and nothing is called")
    func noMatch() async throws {
        let transport = TokenTransport()

        let result = await makeHandler(keychain, transport).callTool(name: "auth_status",
                                                                     arguments: ["workspace": .string("gamma")])

        expectError(result, containing: ["T01 alpha", "T02 beta"])
        #expect(transport.requests.isEmpty)
    }

    @Test("a credential that cannot be read is reported for that workspace only, naming the item")
    func unreadableCredential() async throws {
        keychain.force("SLACK_TOKEN_T02", .absent)
        let transport = TokenTransport([Fake.alphaToken: .body(Fake.authTestOK(team: "T01", user: "U01"))])

        let result = await makeHandler(keychain, transport).callTool(name: "auth_status", arguments: [:])

        #expect(result.isError == false)
        let report = try decode(StatusReport.self, result)
        #expect(report.workspaces.first == Self.alphaValid)
        let beta = try #require(report.workspaces.last)
        #expect(!beta.valid && beta.error_class == "credentialUnavailable")
        #expect(beta.message?.contains("SLACK_TOKEN_T02") == true)
        #expect(transport.tokens == [Fake.alphaToken])
        expectNoSecrets(result)
    }

    @Test("a credential that signs in to another team is not reported valid")
    func teamMismatch() async throws {
        let transport = TokenTransport([Fake.alphaToken: .body(Fake.authTestOK(team: "T09", user: "U01"))])

        let result = await makeHandler(keychain, transport).callTool(name: "auth_status",
                                                                     arguments: ["workspace": .string("alpha")])

        let entry = try #require(try decode(StatusReport.self, result).workspaces.first)
        #expect(!entry.valid && entry.error_class == "teamMismatch")
        #expect(entry.message?.contains("T09") == true)
        expectNoSecrets(result)
    }

    @Test("an index that cannot be read is an error result naming SLACK_WORKSPACES")
    func unreadableIndex() async throws {
        keychain.force("SLACK_WORKSPACES", .timedOut(after: 10))

        let result = await makeHandler(keychain).callTool(name: "auth_status", arguments: [:])

        expectError(result, containing: ["SLACK_WORKSPACES"])
    }
}

@Suite("Tool list and dispatch")
struct ToolListTests {
    func schema(_ name: String) throws -> [String: Value] {
        let tool = try #require(SlackToolHandler.tools.first { $0.name == name })
        return try #require(tool.inputSchema.objectValue)
    }

    @Test("the tools are list_workspaces and auth_status")
    func names() {
        #expect(SlackToolHandler.tools.map(\.name) == ["list_workspaces", "auth_status"])
    }

    @Test("auth_status takes an optional string workspace; list_workspaces takes none")
    func workspaceArgument() throws {
        let status = try schema("auth_status")
        let workspace = try #require(status["properties"]?.objectValue?["workspace"]?.objectValue)
        #expect(workspace["type"] == .string("string"))
        #expect(status["required"]?.arrayValue?.contains(.string("workspace")) != true)

        let list = try schema("list_workspaces")
        #expect(list["properties"]?.objectValue?["workspace"] == nil)
    }

    @Test("an unknown tool is an error result and reads nothing")
    func unknownTool() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])

        let result = await makeHandler(keychain).callTool(name: "send_mesage", arguments: [:])

        expectError(result, containing: ["Unknown tool"])
        #expect(keychain.reads.isEmpty)
    }

    @Test("creating the server and listing tools reads nothing from the Keychain")
    func lazyKeychain() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])

        let server = await CheSlackMCPServer(handler: makeHandler(keychain))
        _ = SlackToolHandler.tools

        #expect(keychain.reads.isEmpty)
        #expect(CheSlackMCPServer.name == "che-slack-mcp")
        withExtendedLifetime(server) {}
    }
}
