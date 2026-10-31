import Foundation
import Testing
import SlackAllCore
import SlackWebLib

/// spec: slack-credentials — "Clipboard import", with a fake clipboard, a
/// scripted terminal, an in-memory Keychain and a transport that answers
/// `auth.test` by token. Nothing here touches the real clipboard or Keychain.
@Suite("slack-all auth import")
struct AuthImportTests {
    let keychain: MemoryKeychain
    let clipboard = FakeClipboard()

    init() { keychain = MemoryKeychain() }

    var store: SlackCredentialStore { SlackCredentialStore(reader: keychain, writer: keychain) }

    /// Runs the import with the user copying `copies` in turn, one per Enter.
    func runImport(copies: [String?], transport: TokenTransport,
                   onEnter: (@Sendable (Int) -> Void)? = nil) async -> (results: [SlackImportResult]?, terminal: ScriptedTerminal, error: (any Error)?) {
        let terminal = ScriptedTerminal(clipboard: clipboard, copies: copies, onEnter: onEnter)
        let command = SlackAuthImport(store: store, client: fakeClient(transport), clipboard: clipboard, terminal: terminal)
        do {
            return (try await command.run(), terminal, nil)
        } catch {
            return (nil, terminal, error)
        }
    }

    // MARK: - The spec scenario

    /// "One of two workspaces fails verification".
    @Test("alpha verifies and beta gets invalid_auth: only alpha is stored, beta is reported rejected with invalid_auth")
    func oneOfTwoFails() async throws {
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01"),
                                        Fake.betaToken: Fake.invalidAuth])

        let (results, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport)

        #expect(error == nil)
        #expect(results == [
            SlackImportResult(workspace: Fake.alpha, outcome: .imported),
            SlackImportResult(workspace: Fake.beta, outcome: .rejected("session invalid (invalid_auth)")),
        ])
        #expect(keychain.contents["SLACK_TOKEN_T01"] == Fake.alphaToken)
        #expect(keychain.contents["SLACK_COOKIE_T01"] == Fake.cookie)
        #expect(keychain.contents["SLACK_TOKEN_T02"] == nil)
        #expect(keychain.contents["SLACK_COOKIE_T02"] == nil)
        #expect(try await store.workspaces() == [Fake.alpha])
        #expect(transport.tokens == [Fake.alphaToken, Fake.betaToken])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "d=\(Fake.cookie)" })
        #expect(terminal.lines.contains("Alpha (alpha, T01): imported"))
        #expect(terminal.lines.contains("Beta (beta, T02): rejected, session invalid (invalid_auth)"))
        #expect(clipboard.current == nil)
        #expect(SlackAuthImport.exitStatus(for: results ?? []) == 0)
        expectNoSecrets(terminal.lines, error)
    }

    @Test("the console command copies id, domain, name, token and user_id of every team in localConfig_v2 with copy()")
    func consoleCommand() async throws {
        let (_, terminal, _) = await runImport(copies: [], transport: TokenTransport([:]))

        #expect(SlackAuthImport.consoleCommand == "copy(JSON.stringify(Object.values(JSON.parse(localStorage.localConfig_v2).teams)"
                + ".map(t=>({id:t.id,domain:t.domain,name:t.name,token:t.token,user_id:t.user_id}))))")
        #expect(terminal.lines.contains(SlackAuthImport.consoleCommand))
        #expect(terminal.lines.contains { $0.contains("app.slack.com") })
    }

    // MARK: - Stopping early

    /// Each case: what the first read finds, and whether it may hold a token
    /// (contains `xox`), in which case the clipboard is cleared.
    static let notWorkspaceLists: [(String?, Bool)] = [
        (nil, false),
        ("", false),
        ("hello", false),
        ("not json xoxc-leak", true),
        (#"{"teams":{"T01":{"token":"xoxc-leak"}}}"#, true),
        ("[1,2]", false),
        ("[]", false),
        (#"[{"id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"}]"#, false),
        (#"[{"id":"T01","domain":"alpha","name":"Alpha","token":5,"user_id":"U01"}]"#, false),
        (#"[{"id":"T01","domain":"alpha","name":"Alpha","token":"xoxc-leak","user_id":null}]"#, true),
    ]

    @Test("a first read that is not a JSON array of workspace objects stops before the cookie step", arguments: notWorkspaceLists)
    func notAWorkspaceList(first: String?, mayHoldToken: Bool) async throws {
        let transport = TokenTransport([:])

        let (results, terminal, error) = await runImport(copies: [first, Fake.cookie], transport: transport)

        #expect(results == nil)
        let thrown = try #require(error as? SlackAuthCommandError)
        #expect(thrown.message.contains("clipboard"))
        #expect(!thrown.message.contains("xoxc-leak"))
        #expect(terminal.enters == 1)
        #expect(!terminal.lines.contains { $0.contains("cookie") })
        #expect(transport.requests.isEmpty)
        #expect(keychain.writes.isEmpty)
        #expect(clipboard.current == (mayHoldToken ? nil : first))
        expectNoSecrets(terminal.lines, error)
    }

    @Test("input that ends at the first prompt stops without reading the clipboard")
    func inputEndsFirst() async throws {
        clipboard.copy("unrelated text")
        let transport = TokenTransport([:])

        let (_, terminal, error) = await runImport(copies: [], transport: transport)

        #expect(error is SlackAuthCommandError)
        #expect(clipboard.current == "unrelated text")
        #expect(clipboard.clears == 0)
        #expect(transport.requests.isEmpty)
        #expect(keychain.writes.isEmpty)
        expectNoSecrets(terminal.lines, error)
    }

    @Test("input that ends at the cookie prompt clears the copied workspace list and stores nothing")
    func inputEndsSecond() async throws {
        let transport = TokenTransport([:])

        let (_, terminal, error) = await runImport(copies: [Fake.clipboardList], transport: transport)

        #expect(error is SlackAuthCommandError)
        #expect(clipboard.current == nil)
        #expect(transport.requests.isEmpty)
        #expect(keychain.writes.isEmpty)
        expectNoSecrets(terminal.lines, error)
    }

    // MARK: - The cookie

    @Test("the cookie is read without surrounding whitespace or a leading d=, and the clipboard is cleared")
    func cookieIsTrimmed() async throws {
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01"),
                                        Fake.betaToken: Fake.authTestOK(team: "T02", user: "U02")])

        let (results, terminal, error) = await runImport(copies: [Fake.clipboardList, "  d=\(Fake.cookie)\n"], transport: transport)

        #expect(error == nil)
        #expect(results?.map(\.outcome) == [.imported, .imported])
        #expect(keychain.contents["SLACK_COOKIE_T01"] == Fake.cookie)
        #expect(keychain.contents["SLACK_COOKIE_T02"] == Fake.cookie)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Cookie") == "d=\(Fake.cookie)")
        #expect(clipboard.current == nil)
        #expect(clipboard.clears >= 1)
        expectNoSecrets(terminal.lines, error)
    }

    /// The second read still holding the workspace list (the cookie was
    /// never copied), or nothing, or text with a character a cookie value
    /// cannot have: the import stops before any `auth.test`.
    @Test("a second read that is not a cookie value stops before any auth.test, with the clipboard cleared",
          arguments: [Fake.clipboardList, "", "   ", "d=", "xoxd-a b", #"xoxd-"quoted""#])
    func notACookie(second: String) async throws {
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let (results, terminal, error) = await runImport(copies: [Fake.clipboardList, second], transport: transport)

        #expect(results == nil)
        #expect((error as? SlackAuthCommandError)?.message.contains("cookie") == true)
        #expect(transport.requests.isEmpty)
        #expect(keychain.writes.isEmpty)
        #expect(clipboard.current == nil)
        expectNoSecrets(terminal.lines, error)
    }

    // MARK: - What is stored

    @Test("re-importing merges by team id: alpha's entry is replaced in place and gamma stays")
    func mergesIntoIndex() async throws {
        let gamma = SlackWorkspace(teamID: "T03", domain: "gamma", name: "Gamma", userID: "U03")
        let oldAlpha = SlackWorkspace(teamID: "T01", domain: "alpha", name: "Old Alpha", userID: "U01")
        try await store.saveWorkspaces([oldAlpha, gamma])
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let (_, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport)

        #expect(error == nil)
        #expect(try await store.workspaces() == [Fake.alpha, gamma])
        expectNoSecrets(terminal.lines, error)
    }

    /// "Index changed while the import waits".
    @Test("an index change made by another process while the import waits for the cookie is kept")
    func indexChangedWhileWaiting() async throws {
        let gamma = SlackWorkspace(teamID: "T03", domain: "gamma", name: "Gamma", userID: "U03")
        let delta = SlackWorkspace(teamID: "T04", domain: "delta", name: "Delta", userID: "U04")
        let epsilon = SlackWorkspace(teamID: "T05", domain: "epsilon", name: "Epsilon", userID: "U05")
        try await store.saveWorkspaces([gamma, delta])
        let changed = try await indexValue([delta, epsilon])
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let keychain = self.keychain
        let (_, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport) { enter in
            if enter == 2 { keychain.writeFromAnotherProcess(service: "SLACK_WORKSPACES", value: changed) }
        }

        #expect(error == nil)
        #expect(try await store.workspaces() == [delta, epsilon, Fake.alpha])
        expectNoSecrets(terminal.lines, error)
    }

    @Test("a workspace whose credential could not be written is reported not stored and left out of the index")
    func failedWriteIsNotIndexed() async throws {
        let failure = SlackKeychainWriteError.failed(service: "SLACK_COOKIE_T01", reason: "security -i exited with status 1")
        keychain.failWrites(to: "SLACK_COOKIE_T01", with: failure)
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01"),
                                        Fake.betaToken: Fake.authTestOK(team: "T02", user: "U02")])

        let (results, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport)

        #expect(error == nil)
        #expect(results == [
            SlackImportResult(workspace: Fake.alpha, outcome: .notStored(failure.description)),
            SlackImportResult(workspace: Fake.beta, outcome: .imported),
        ])
        #expect(try await store.workspaces() == [Fake.beta])
        #expect(terminal.lines.contains("Alpha (alpha, T01): not stored, \(failure.description)"))
        expectNoSecrets(terminal.lines, error)
    }

    @Test("when no workspace is imported the index is not written and the exit status is 1")
    func nothingImported() async throws {
        let transport = TokenTransport([:])

        let (results, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport)

        #expect(error == nil)
        #expect(results?.map(\.outcome) == [.rejected("session invalid (invalid_auth)"), .rejected("session invalid (invalid_auth)")])
        #expect(keychain.writes.isEmpty)
        #expect(SlackAuthImport.exitStatus(for: results ?? []) == 1)
        expectNoSecrets(terminal.lines, error)
    }

    @Test("an index write that fails is an error naming SLACK_WORKSPACES and the workspaces it does not list")
    func indexWriteFails() async throws {
        keychain.failWrites(to: "SLACK_WORKSPACES", with: .failed(service: "SLACK_WORKSPACES", reason: "security -i exited with status 1"))
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let (_, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport)

        let thrown = try #require(error as? SlackAuthCommandError)
        #expect(thrown.message.contains("SLACK_WORKSPACES"))
        #expect(thrown.message.contains("Alpha (alpha, T01)"))
        expectNoSecrets(terminal.lines, error)
    }

    @Test("an auth.test answer for another team is rejected and nothing is stored for it")
    func otherTeamIsRejected() async throws {
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T99", user: "U01"),
                                        Fake.betaToken: Fake.authTestOK(team: "T02", user: "U02")])

        let (results, terminal, error) = await runImport(copies: [Fake.clipboardList, Fake.cookie], transport: transport)

        #expect(error == nil)
        #expect(results?.first?.outcome == .rejected("auth.test answered for team T99"))
        #expect(keychain.contents["SLACK_TOKEN_T01"] == nil)
        #expect(try await store.workspaces() == [Fake.beta])
        expectNoSecrets(terminal.lines, error)
    }

    @Test("a team id the Keychain layout cannot hold is rejected without calling auth.test", arguments: ["t01", #"T01"x"#, ""])
    func badTeamIDIsRejected(id: String) async throws {
        let list = #"[{"id":"\#(id.replacingOccurrences(of: "\"", with: "\\\""))","domain":"alpha","name":"Alpha","token":"\#(Fake.alphaToken)","user_id":"U01"}]"#
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: id, user: "U01")])

        let (results, terminal, error) = await runImport(copies: [list, Fake.cookie], transport: transport)

        #expect(error == nil)
        guard case .rejected(let reason)? = results?.first?.outcome else {
            Issue.record("expected a rejection, got \(String(describing: results))")
            return
        }
        #expect(reason.contains("SLACK_TOKEN_"))
        #expect(transport.requests.isEmpty)
        #expect(keychain.writes.isEmpty)
        expectNoSecrets(terminal.lines, error)
    }

    /// The console command copies whatever Slack holds; a name is not
    /// trusted to be free of credentials, so every line is scrubbed.
    @Test("a name or domain that contains a token or the cookie is printed with them redacted")
    func namesAreScrubbed() async throws {
        let list = #"[{"id":"T01","domain":"alpha-\#(Fake.cookie)","name":"Alpha \#(Fake.alphaToken)","token":"\#(Fake.alphaToken)","user_id":"U01"}]"#
        keychain.failWrites(to: "SLACK_WORKSPACES", with: .failed(service: "SLACK_WORKSPACES", reason: "security -i exited with status 1"))
        let transport = TokenTransport([Fake.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let (_, terminal, error) = await runImport(copies: [list, Fake.cookie], transport: transport)

        #expect(terminal.lines.contains("Alpha <redacted> (alpha-<redacted>, T01): imported"))
        #expect(error is SlackAuthCommandError)
        expectNoSecrets(terminal.lines, error)
    }

    @Test("a malformed index stops the import before the user is asked to copy anything")
    func malformedIndexStops() async throws {
        let broken = MemoryKeychain(["SLACK_WORKSPACES": "not base64!"])
        let terminal = ScriptedTerminal(clipboard: clipboard, copies: [Fake.clipboardList, Fake.cookie])
        let command = SlackAuthImport(store: SlackCredentialStore(reader: broken, writer: broken),
                                      client: fakeClient(TokenTransport([:])), clipboard: clipboard, terminal: terminal)

        await #expect(throws: SlackCredentialError.malformedIndex(reason: "is not valid base64")) {
            _ = try await command.run()
        }
        #expect(terminal.enters == 0)
        #expect(broken.writes.isEmpty)
    }
}
