import Foundation
import Testing
import SlackAllCore
import SlackWebLib

/// spec: slack-credentials — "Workspace removal", with an in-memory Keychain
/// holding `alpha` (T01) and `beta` (T02).
@Suite("slack-all auth remove")
struct AuthRemoveTests {
    let keychain: MemoryKeychain
    let terminal = ScriptedTerminal(clipboard: FakeClipboard())

    init() async throws {
        keychain = MemoryKeychain([
            "SLACK_WORKSPACES": try await indexValue([Fake.alpha, Fake.beta]),
            "SLACK_TOKEN_T01": Fake.alphaToken, "SLACK_COOKIE_T01": Fake.cookie,
            "SLACK_TOKEN_T02": Fake.betaToken, "SLACK_COOKIE_T02": Fake.cookie,
        ])
    }

    var store: SlackCredentialStore { SlackCredentialStore(reader: keychain, writer: keychain) }

    func remove(_ query: String) async -> (any Error)? {
        do {
            try await SlackAuthRemove(store: store, terminal: terminal).run(query)
            return nil
        } catch {
            return error
        }
    }

    /// "Remove by domain".
    @Test("remove alpha deletes T01's token and cookie, leaves only T02 in the index, and T02's items unchanged")
    func removeByDomain() async throws {
        let error = await remove("alpha")

        #expect(error == nil)
        #expect(keychain.contents["SLACK_TOKEN_T01"] == nil)
        #expect(keychain.contents["SLACK_COOKIE_T01"] == nil)
        #expect(try await store.workspaces() == [Fake.beta])
        #expect(keychain.contents["SLACK_TOKEN_T02"] == Fake.betaToken)
        #expect(keychain.contents["SLACK_COOKIE_T02"] == Fake.cookie)
        #expect(keychain.deletes == ["SLACK_TOKEN_T01", "SLACK_COOKIE_T01"])
        #expect(terminal.lines.contains { $0.contains("Alpha (alpha, T01)") })
        expectNoSecrets(terminal.lines, error)
    }

    @Test("remove accepts a team id or a domain, in any case", arguments: ["T02", "t02", "BETA"])
    func removeByTeamID(query: String) async throws {
        let error = await remove(query)

        #expect(error == nil)
        #expect(try await store.workspaces() == [Fake.alpha])
        #expect(keychain.deletes == ["SLACK_TOKEN_T02", "SLACK_COOKIE_T02"])
        expectNoSecrets(terminal.lines, error)
    }

    @Test("a workspace that does not match is an error listing the imported workspaces, and nothing changes",
          arguments: ["gamma", "alph", "Alpha (alpha, T01)", ""])
    func noMatch(query: String) async throws {
        let before = keychain.contents

        let error = await remove(query)

        let message = try #require((error as? SlackAuthCommandError)?.message)
        #expect(message.contains("Alpha (alpha, T01)"))
        #expect(message.contains("Beta (beta, T02)"))
        #expect(keychain.contents == before)
        #expect(keychain.deletes.isEmpty)
        #expect(keychain.writes.isEmpty)
        expectNoSecrets(terminal.lines, error)
    }

    @Test("with nothing imported, remove is an error suggesting slack-all auth import")
    func nothingImported() async throws {
        let empty = MemoryKeychain()

        await #expect(throws: SlackAuthCommandError.self) {
            try await SlackAuthRemove(store: SlackCredentialStore(reader: empty, writer: empty), terminal: terminal).run("alpha")
        }
        #expect(empty.deletes.isEmpty)
        #expect(empty.writes.isEmpty)
    }

    @Test("a delete that fails is an error naming the item; the index still lists the workspace")
    func deleteFails() async throws {
        let failure = SlackKeychainDeleteError.failed(service: "SLACK_COOKIE_T01", reason: "security exited with status 1")
        keychain.failDeletes(of: "SLACK_COOKIE_T01", with: failure)

        let error = await remove("alpha")

        let message = try #require((error as? SlackAuthCommandError)?.message)
        #expect(message.contains("SLACK_COOKIE_T01"))
        #expect(try await store.workspaces() == [Fake.alpha, Fake.beta])
        #expect(keychain.writes.isEmpty)
        expectNoSecrets(terminal.lines, error)
    }

    @Test("a query that matches two workspaces (one's team id, another's domain) is an error and nothing changes")
    func ambiguous() async throws {
        let odd = SlackWorkspace(teamID: "T03", domain: "t01", name: "Odd", userID: "U03")
        try await store.saveWorkspaces([Fake.alpha, Fake.beta, odd])
        let writesBefore = keychain.writes

        let error = await remove("T01")

        let message = try #require((error as? SlackAuthCommandError)?.message)
        #expect(message.contains("Alpha (alpha, T01)"))
        #expect(message.contains("Odd (t01, T03)"))
        #expect(keychain.deletes.isEmpty)
        #expect(keychain.writes == writesBefore)
    }
}

/// `slack-all auth status` (design: CLI 介面).
@Suite("slack-all auth status")
struct AuthStatusTests {
    let terminal = ScriptedTerminal(clipboard: FakeClipboard())

    @Test("each imported workspace gets one line with its auth.test result or why it could not be checked")
    func reportsEachWorkspace() async throws {
        let gamma = SlackWorkspace(teamID: "T03", domain: "gamma", name: "Gamma", userID: "U03")
        let keychain = MemoryKeychain([
            "SLACK_WORKSPACES": try await indexValue([Fake.alpha, Fake.beta, gamma]),
            "SLACK_TOKEN_T01": Fake.alphaToken, "SLACK_COOKIE_T01": Fake.cookie,
            "SLACK_TOKEN_T02": Fake.betaToken, "SLACK_COOKIE_T02": Fake.cookie,
        ])
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01"),
                                        Fake.betaToken: Fake.invalidAuth])

        let allValid = try await SlackAuthStatus(store: SlackCredentialStore(reader: keychain, writer: keychain),
                                                 client: fakeClient(transport), terminal: terminal).run()

        #expect(!allValid)
        #expect(terminal.lines == [
            "Alpha (alpha, T01): valid",
            "Beta (beta, T02): session invalid (invalid_auth)",
            "Gamma (gamma, T03): Keychain item SLACK_TOKEN_T03 is not stored (account che-slack-mcp).",
        ])
        #expect(keychain.writes.isEmpty)
        expectNoSecrets(terminal.lines)
    }

    @Test("every workspace valid gives true")
    func allValid() async throws {
        let keychain = MemoryKeychain([
            "SLACK_WORKSPACES": try await indexValue([Fake.alpha]),
            "SLACK_TOKEN_T01": Fake.alphaToken, "SLACK_COOKIE_T01": Fake.cookie,
        ])
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let allValid = try await SlackAuthStatus(store: SlackCredentialStore(reader: keychain, writer: keychain),
                                                 client: fakeClient(transport), terminal: terminal).run()

        #expect(allValid)
        #expect(terminal.lines == ["Alpha (alpha, T01): valid"])
        expectNoSecrets(terminal.lines)
    }

    @Test("with nothing imported, status says so, suggests slack-all auth import, and gives false")
    func nothingImported() async throws {
        let keychain = MemoryKeychain()

        let allValid = try await SlackAuthStatus(store: SlackCredentialStore(reader: keychain, writer: keychain),
                                                 client: fakeClient(TokenTransport([:])), terminal: terminal).run()

        #expect(!allValid)
        #expect(terminal.lines.count == 1)
        #expect(terminal.lines.first?.contains("slack-all auth import") == true)
    }
}
