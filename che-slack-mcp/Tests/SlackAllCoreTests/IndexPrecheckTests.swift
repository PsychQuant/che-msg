import Foundation
import Testing
@testable import SlackWebLib
@testable import SlackAllCore

/// spec: slack-credentials — "Keychain credential layout", scenario "Index
/// that would not fit is refused before any write": before an import calls
/// `auth.test` or writes anything, it checks that the index it could leave
/// fits one write as "Keychain write keeps values off argv" defines it (one
/// `security -i` line of at most 4094 bytes). The Keychain is in memory with
/// the production writer's checks, the workspaces are `ManyWorkspaces`, and
/// `auth.test` is answered by a fake transport. The desktop import's case is
/// in `DesktopImportTests`.
@Suite("An import whose index would not fit one Keychain write")
struct IndexPrecheckTests {
    struct Run {
        let results: [SlackImportResult]?
        let terminal: ScriptedTerminal
        let clipboard: FakeClipboard
        let error: (any Error)?
    }

    /// Runs the clipboard import against `keychain`, the user copying `list`
    /// and then the cookie.
    func runImport(_ keychain: MemoryKeychain, list: String, transport: TokenTransport) async -> Run {
        let clipboard = FakeClipboard()
        let terminal = ScriptedTerminal(clipboard: clipboard, copies: [list, Fake.cookie])
        let command = SlackAuthImport(store: SlackCredentialStore(reader: keychain, writer: keychain),
                                      client: fakeClient(transport), clipboard: clipboard, terminal: terminal)
        do {
            return Run(results: try await command.run(), terminal: terminal, clipboard: clipboard, error: nil)
        } catch {
            return Run(results: nil, terminal: terminal, clipboard: clipboard, error: error)
        }
    }

    static func workspaces(_ numbers: ClosedRange<Int>) -> [SlackWorkspace] { numbers.map(ManyWorkspaces.workspace) }

    // MARK: - The spec scenario

    /// "Index that would not fit is refused before any write".
    @Test("40 workspaces whose index would not fit: no Keychain write, no auth.test, and the error names 40 and slack-all auth remove")
    func fortyWorkspaces() async throws {
        #expect(try await !IndexLimit.fits(Self.workspaces(1...40)))
        let keychain = MemoryKeychain()
        let transport = ManyWorkspaces.transport(1...40)

        let run = await runImport(keychain, list: ManyWorkspaces.clipboardList(1...40), transport: transport)

        #expect(run.results == nil)
        let thrown = try #require(run.error as? SlackAuthCommandError)
        #expect(thrown.message == "Nothing was imported: the workspace index SLACK_WORKSPACES would list up to 40 workspaces "
            + "(0 already imported, 40 new) and would not fit in one Keychain write. Remove workspaces you no longer use "
            + "with slack-all auth remove <workspace>, or import fewer by signing out of some in the browser or the Slack "
            + "desktop app, then run the import again.")
        #expect(keychain.writes.isEmpty)
        #expect(keychain.contents.isEmpty)
        #expect(transport.requests.isEmpty)
        // Refused right after the workspace list is read: the cookie is never
        // asked for, and the list, which holds the tokens, is cleared.
        #expect(run.terminal.enters == 1)
        #expect(!run.terminal.lines.contains { $0.hasPrefix("Step 2 of 2") })
        #expect(run.clipboard.current == nil)
        ManyWorkspaces.expectNoTokens(run.terminal.lines, run.error)
        expectNoSecrets(run.terminal.lines, run.error)
    }

    // MARK: - What counts

    @Test("the existing index counts: two new workspaces that fit on their own are refused when it holds all but one that fit")
    func existingEntriesCount() async throws {
        let capacity = try await IndexLimit.capacity()
        let index = try await indexValue(Self.workspaces(1...capacity - 1))
        let keychain = MemoryKeychain(["SLACK_WORKSPACES": index])
        let newOnes = capacity...capacity + 1
        #expect(try await IndexLimit.fits(Self.workspaces(newOnes)))
        let transport = ManyWorkspaces.transport(newOnes)

        let run = await runImport(keychain, list: ManyWorkspaces.clipboardList(newOnes), transport: transport)

        let thrown = try #require(run.error as? SlackAuthCommandError)
        #expect(thrown.message.contains("would list up to \(capacity + 1) workspaces (\(capacity - 1) already imported, 2 new)"))
        #expect(thrown.message.contains("slack-all auth remove"))
        #expect(keychain.writes.isEmpty)
        #expect(keychain.contents == ["SLACK_WORKSPACES": index])
        #expect(transport.requests.isEmpty)
        ManyWorkspaces.expectNoTokens(run.terminal.lines, run.error)
    }

    @Test("re-importing every workspace of a full index is not refused: each is counted once")
    func reimportOfFullIndex() async throws {
        let capacity = try await IndexLimit.capacity()
        let all = Self.workspaces(1...capacity)
        let keychain = MemoryKeychain(["SLACK_WORKSPACES": try await indexValue(all)])
        let transport = ManyWorkspaces.transport(1...capacity)

        let run = await runImport(keychain, list: ManyWorkspaces.clipboardList(1...capacity), transport: transport)

        #expect(run.error == nil)
        #expect(run.results?.map(\.outcome) == Array(repeating: .imported, count: capacity))
        #expect(try await SlackCredentialStore(reader: keychain, writer: keychain).workspaces() == all)
        #expect(transport.requests.count == capacity)
    }

    /// A re-import whose `auth.test` fails leaves the existing entry in the
    /// index, so the check counts whichever of the two entries is longer.
    @Test("a re-imported workspace with a shorter name is counted at its existing, longer entry")
    func shorterReimportCountsLonger() async throws {
        let capacity = try await IndexLimit.capacity()
        let first = ManyWorkspaces.workspace(1)
        var padding = 0
        var longer = first
        repeat {
            padding += 1
            longer = SlackWorkspace(teamID: first.teamID, domain: first.domain,
                                    name: first.name + String(repeating: "x", count: padding), userID: first.userID)
        } while try await IndexLimit.fits([longer] + Self.workspaces(2...capacity))
        let existing = [longer] + Self.workspaces(2...capacity - 1)
        #expect(try await IndexLimit.fits(existing))
        // Imported under its shorter name together with one new workspace,
        // the index would fit; with the longer name kept, it would not.
        #expect(try await IndexLimit.fits(Self.workspaces(1...capacity)))
        let keychain = MemoryKeychain(["SLACK_WORKSPACES": try await indexValue(existing)])
        let transport = ManyWorkspaces.transport([1, capacity])

        let run = await runImport(keychain, list: ManyWorkspaces.clipboardList([1, capacity]), transport: transport)

        let thrown = try #require(run.error as? SlackAuthCommandError)
        #expect(thrown.message.contains("would list up to \(capacity) workspaces (\(capacity - 1) already imported, 1 new)"))
        #expect(keychain.writes.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    // MARK: - The boundary

    @Test("the largest number of workspaces whose index fits one write is imported; one more is refused")
    func boundary() async throws {
        let capacity = try await IndexLimit.capacity()
        #expect(capacity > 1)

        let fitting = MemoryKeychain()
        let fittingRun = await runImport(fitting, list: ManyWorkspaces.clipboardList(1...capacity),
                                         transport: ManyWorkspaces.transport(1...capacity))
        #expect(fittingRun.error == nil)
        #expect(fittingRun.results?.map(\.outcome) == Array(repeating: .imported, count: capacity))
        #expect(try await SlackCredentialStore(reader: fitting, writer: fitting).workspaces() == Self.workspaces(1...capacity))

        let over = MemoryKeychain()
        let overTransport = ManyWorkspaces.transport(1...capacity + 1)
        let overRun = await runImport(over, list: ManyWorkspaces.clipboardList(1...capacity + 1), transport: overTransport)
        let thrown = try #require(overRun.error as? SlackAuthCommandError)
        #expect(thrown.message.contains("would list up to \(capacity + 1) workspaces"))
        #expect(over.writes.isEmpty)
        #expect(overTransport.requests.isEmpty)
    }

    // MARK: - The shared path

    @Test("ImportVerifier, which both imports use, checks the index before any auth.test or write")
    func verifierChecksFirst() async throws {
        let keychain = MemoryKeychain()
        let transport = ManyWorkspaces.transport(1...40)
        let terminal = RecordingTerminal()
        let verifier = ImportVerifier(store: SlackCredentialStore(reader: keychain, writer: keychain),
                                      client: fakeClient(transport), terminal: terminal)
        let candidates = try ClipboardImport.candidates(from: ManyWorkspaces.clipboardList(1...40))

        let error = await #expect(throws: SlackAuthCommandError.self) {
            _ = try await verifier.verifyAndStore(candidates, cookie: Fake.cookie,
                                                  redact: Redaction(secrets: candidates.map(\.token) + [Fake.cookie]))
        }

        #expect(error?.message.contains("up to 40 workspaces") == true)
        #expect(keychain.writes.isEmpty)
        #expect(transport.requests.isEmpty)
        #expect(terminal.lines.isEmpty)
    }
}

/// The test's own reading of "one Keychain write": the `security -i` line
/// for the index, as the store writes it, is at most `maxLineBytes` long.
enum IndexLimit {
    static func fits(_ workspaces: [SlackWorkspace]) async throws -> Bool {
        let line = MemoryKeychain.productionChecks.commandLine(service: SlackKeychain.workspacesService,
                                                                value: try await indexValue(workspaces))
        return line.utf8.count <= SecurityCLIKeychainWriter.maxLineBytes
    }

    /// The largest number of `ManyWorkspaces` whose index fits.
    static func capacity() async throws -> Int {
        var count = 0
        while try await fits((1...count + 1).map(ManyWorkspaces.workspace)) { count += 1 }
        return count
    }
}
