import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// One row of the spec's "Example: selection outcomes" table.
struct SelectionRow: Sendable, CustomTestStringConvertible {
    enum Outcome: Sendable {
        case uses(String)
        case errorListing([String])
        case errorSuggestingImport
    }

    let imported: [SlackWorkspace]
    let argument: String?
    let outcome: Outcome

    var testDescription: String {
        let list = imported.isEmpty ? "(none)" : imported.map { "\($0.teamID) \($0.domain)" }.joined(separator: ", ")
        return "\(list) + \(argument.map { "`\($0)`" } ?? "(omitted)")"
    }

    var arguments: [String: Value] { argument.map { ["workspace": .string($0)] } ?? [:] }
}

@Suite("Workspace selection")
struct WorkspaceSelectionTests {
    /// spec: slack-mcp-tools, "Example: selection outcomes", row by row.
    static let table: [SelectionRow] = [
        SelectionRow(imported: [Fake.alpha], argument: nil, outcome: .uses("T01")),
        SelectionRow(imported: [Fake.alpha, Fake.beta], argument: "BETA", outcome: .uses("T02")),
        SelectionRow(imported: [Fake.alpha, Fake.beta], argument: "t01", outcome: .uses("T01")),
        SelectionRow(imported: [Fake.alpha, Fake.beta], argument: "gamma", outcome: .errorListing(["T01 alpha", "T02 beta"])),
        SelectionRow(imported: [], argument: nil, outcome: .errorSuggestingImport),
    ]

    @Test("selection outcomes", arguments: table)
    func selectionOutcomes(row: SelectionRow) async throws {
        let keychain = try await MemoryKeychain.with(row.imported)
        let resolved = await makeHandler(keychain).resolver.resolve(row.arguments)

        switch (row.outcome, resolved) {
        case let (.uses(teamID), .success(selection)):
            #expect(selection.workspace.teamID == teamID)
            #expect(selection.credential.teamID == teamID)
            #expect(selection.credential.token == Fake.defaultCredentials[teamID]?.token)
        case let (.errorListing(labels), .failure(failure)):
            expectError(failure.result, containing: labels)
        case let (.errorSuggestingImport, .failure(failure)):
            expectError(failure.result, containing: ["slack-all auth import", "slack-all auth import --from-desktop"])
        default:
            Issue.record("expected \(row.outcome), got \(resolved)")
        }
        #expect(keychain.changes.isEmpty)
    }
}

@Suite("Workspace selection refusals")
struct WorkspaceSelectionRefusalTests {
    func resolve(_ keychain: MemoryKeychain, _ arguments: [String: Value]) async -> Result<ResolvedWorkspace, ToolFailure> {
        await makeHandler(keychain).resolver.resolve(arguments)
    }

    func failure(_ result: Result<ResolvedWorkspace, ToolFailure>) -> CallTool.Result? {
        if case let .failure(failure) = result { return failure.result }
        Issue.record("expected a refusal, got \(result)")
        return nil
    }

    /// spec: slack-mcp-tools, "Ambiguous call is refused".
    @Test("omitting workspace while two are imported is refused, listing both, and no credential is read")
    func ambiguousOmission() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])

        let result = try #require(failure(await resolve(keychain, [:])))

        expectError(result, containing: ["T01 alpha", "T02 beta", "workspace"])
        #expect(keychain.reads == ["SLACK_WORKSPACES"])
    }

    @Test("a workspace argument that is not a string is refused, naming it, before the Keychain is read",
          arguments: [Value.int(1), .bool(true), .double(1.5), .array([.string("alpha")]), .object(["domain": .string("alpha")])])
    func nonString(value: Value) async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])

        let result = try #require(failure(await resolve(keychain, ["workspace": value])))

        expectError(result, containing: ["workspace must be a string"])
        #expect(keychain.reads.isEmpty)
    }

    @Test("workspace null counts as omitted")
    func nullIsOmitted() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])

        let selection = try await resolve(keychain, ["workspace": .null]).get()

        #expect(selection.workspace == Fake.alpha)
    }

    @Test("an empty workspace is refused even when only one is imported, listing it")
    func emptyString() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])

        let result = try #require(failure(await resolve(keychain, ["workspace": .string("")])))

        expectError(result, containing: ["workspace is empty", "T01 alpha"])
        #expect(keychain.reads == ["SLACK_WORKSPACES"])
    }

    @Test("a value that is one workspace's domain and another's team id picks neither")
    func twoMatches() async throws {
        let odd = SlackWorkspace(teamID: "T01", domain: "t02", name: "Odd", userID: "U01")
        let keychain = try await MemoryKeychain.with([odd, Fake.beta])

        let result = try #require(failure(await resolve(keychain, ["workspace": .string("T02")])))

        expectError(result, containing: ["more than one", "T01 t02", "T02 beta"])
        #expect(keychain.reads == ["SLACK_WORKSPACES"])
    }

    @Test("a value matching nothing is not repeated in the refusal")
    func queryNotEchoed() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])

        let result = try #require(failure(await resolve(keychain, ["workspace": .string(Fake.betaToken)])))

        expectError(result, containing: ["T01 alpha", "T02 beta"])
    }

    @Test("an index that cannot be read is refused naming SLACK_WORKSPACES, not taken for nothing imported",
          arguments: [KeychainLookup.timedOut(after: 10), .unavailable(reason: "security exited 1"), .found("not base64!")])
    func unreadableIndex(lookup: KeychainLookup) async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])
        keychain.force("SLACK_WORKSPACES", lookup)

        let result = try #require(failure(await resolve(keychain, [:])))

        expectError(result, containing: ["SLACK_WORKSPACES"])
        #expect(!text(result).contains("No Slack workspace is imported"))
    }

    @Test("a missing token for the selected workspace is refused naming the item and both import commands")
    func missingToken() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
        keychain.force("SLACK_TOKEN_T02", .absent)

        let result = try #require(failure(await resolve(keychain, ["workspace": .string("beta")])))

        expectError(result, containing: ["SLACK_TOKEN_T02", "beta",
                                         "slack-all auth import", "slack-all auth import --from-desktop"])
    }

    @Test("a cookie that cannot be read is refused naming the item")
    func unreadableCookie() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha])
        keychain.force("SLACK_COOKIE_T01", .timedOut(after: 10))

        let result = try #require(failure(await resolve(keychain, [:])))

        expectError(result, containing: ["SLACK_COOKIE_T01"])
    }
}
