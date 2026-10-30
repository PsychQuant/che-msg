import Foundation
import Testing
import SlackWebLib
@testable import SlackAllCore

/// spec: slack-credentials — "Desktop import". Every Slack folder here is
/// synthetic, built in a temporary "home": a `Cookies` database holding the
/// `CookieFixture` ciphertext (encrypted with a test password by openssl),
/// and a `Local Storage/leveldb` folder written by `LevelDBFixture`. The
/// Safe Storage password comes from a fake, the Keychain is in memory, and
/// `auth.test` is answered by a fake transport.
@Suite("slack-all auth import --from-desktop")
final class DesktopImportTests {
    let root: URL
    let home: URL
    let scratch: URL
    let keychain = MemoryKeychain()
    let terminal = RecordingTerminal()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop import test \(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        scratch = root.appendingPathComponent("scratch dir")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        try? FileManager.default.removeItem(at: root)
    }

    static let alphaToken = "xoxc-test-alpha-1111"
    static let betaToken = "xoxc-test-beta-2222"
    static let secrets = [alphaToken, betaToken, CookieFixture.cookie, CookieFixture.password]

    static let config = """
        {"teams":{"T02":{"id":"T02","domain":"beta","name":"Beta","token":"\(betaToken)","user_id":"U02"},
        "T01":{"id":"T01","domain":"alpha","name":"Alpha","token":"\(alphaToken)","user_id":"U01","x":[1]}}}
        """
    static let olderConfig = #"{"teams":{"T09":{"id":"T09","domain":"old","name":"Old","token":"xoxc-test-old","user_id":"U09"}}}"#

    var containerFolder: URL { SlackDesktopData.standard(home: home).candidates[0] }
    var plainFolder: URL { SlackDesktopData.standard(home: home).candidates[1] }
    var store: SlackCredentialStore { SlackCredentialStore(reader: keychain, writer: keychain) }

    /// `localConfig_v2` as Chromium stores it: a marker byte, then Latin-1
    /// (1) or UTF-16LE (0) text.
    static func stored(_ text: String, utf16: Bool = false) -> [UInt8] {
        utf16 ? [0] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } : [1] + Array(text.utf8)
    }

    static let storedConfig = stored(config)
    static let cookieRows = [CookieDatabaseTests.Row(encrypted: CookieFixture.v24)]

    /// A Slack data folder at `folder`: a table with an older config and a
    /// log with `config` (newer; nil writes a deletion), plus `Cookies`
    /// holding `cookies`.
    func makeSlackFolder(at folder: URL, config: [UInt8]? = DesktopImportTests.storedConfig,
                         cookies: [CookieDatabaseTests.Row] = DesktopImportTests.cookieRows) throws {
        let leveldb = folder.appendingPathComponent("Local Storage/leveldb")
        try FileManager.default.createDirectory(at: leveldb, withIntermediateDirectories: true)
        let key = LevelDBTests.wanted
        let table = LevelDBFixture.table([(LevelDBFixture.internalKey(key, sequence: 4), Self.stored(Self.olderConfig))])
        try Data(table).write(to: leveldb.appendingPathComponent("000005.ldb"))
        if let config {
            let log = LevelDBFixture.log([LevelDBFixture.writeBatch(sequence: 10, [.put(key: key, value: config)])])
            try Data(log).write(to: leveldb.appendingPathComponent("000007.log"))
        } else {
            let log = LevelDBFixture.log([LevelDBFixture.writeBatch(sequence: 10, [.delete(key: key)])])
            try Data(log).write(to: leveldb.appendingPathComponent("000007.log"))
        }
        for name in ["LOCK", "LOG", "CURRENT", "MANIFEST-000001"] {
            try Data("not read".utf8).write(to: leveldb.appendingPathComponent(name))
        }
        try CookieDatabaseTests.writeDatabase(to: folder.appendingPathComponent("Cookies"), version: "24", rows: cookies)
    }

    func command(safeStorage: FakeSafeStorage, transport: TokenTransport) -> SlackDesktopImport {
        SlackDesktopImport(store: store, client: fakeClient(transport), terminal: terminal,
                           data: SlackDesktopData.standard(home: home), safeStorage: safeStorage, temporaryDirectory: scratch)
    }

    func run(_ safeStorage: FakeSafeStorage, _ transport: TokenTransport) async -> (results: [SlackImportResult]?, error: (any Error)?) {
        do {
            return (try await command(safeStorage: safeStorage, transport: transport).run(), nil)
        } catch {
            return (nil, error)
        }
    }

    var scratchContents: [String] { (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["<unlistable>"] }

    func expectNoSecrets(_ error: (any Error)?) {
        let texts = terminal.lines + (error.map { ["\($0)"] } ?? [])
        for secret in Self.secrets {
            #expect(!texts.contains { $0.contains(secret) }, "output contains a fake credential")
        }
    }

    // MARK: - Locating the data

    @Test("the two data folders are the App Store container's, then ~/Library/Application Support/Slack")
    func standardFolders() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(SlackDesktopData.standard(home: home).candidates.map(\.path) == [
            "/Users/someone/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack",
            "/Users/someone/Library/Application Support/Slack",
        ])
    }

    @Test("the first folder holding Cookies and Local Storage/leveldb is used; else the first that exists; else none")
    func locate() throws {
        let data = SlackDesktopData.standard(home: home)
        #expect(data.locate() == nil)

        try Data().write(to: home.appendingPathComponent("Library-file"))
        #expect(SlackDesktopData(candidates: [home.appendingPathComponent("Library-file")]).locate() == nil)

        try FileManager.default.createDirectory(at: containerFolder, withIntermediateDirectories: true)
        #expect(data.locate()?.standardizedFileURL == containerFolder.standardizedFileURL)

        try makeSlackFolder(at: plainFolder)
        #expect(data.locate()?.standardizedFileURL == plainFolder.standardizedFileURL)

        try makeSlackFolder(at: containerFolder)
        #expect(data.locate()?.standardizedFileURL == containerFolder.standardizedFileURL)
    }

    // MARK: - The spec scenario

    /// "Slack desktop app is not installed".
    @Test("neither data folder exists: stops naming the step, says no Slack desktop data was found, suggests slack-all auth import, changes no Keychain item")
    func notInstalled() async throws {
        try await store.saveWorkspaces([Fake.alpha])
        let before = keychain.contents
        let writesBefore = keychain.writes
        let safeStorage = FakeSafeStorage(.found(CookieFixture.password), terminal: terminal)
        let transport = TokenTransport([:])

        let (results, error) = await run(safeStorage, transport)

        #expect(results == nil)
        let thrown = try #require(error as? SlackDesktopImportError)
        #expect(thrown.step == .findDataFolder)
        #expect(thrown.description.contains("No Slack desktop data was found"))
        #expect(thrown.description.contains("slack-all auth import"))
        #expect(thrown.description.contains(containerFolder.path))
        #expect(thrown.description.contains(plainFolder.path))
        #expect(keychain.contents == before)
        #expect(keychain.writes == writesBefore)
        #expect(safeStorage.reads == 0)
        #expect(transport.requests.isEmpty)
        #expect(scratchContents.isEmpty)
    }

    // MARK: - Importing

    @Test("the newest localConfig_v2 and the decrypted d cookie are verified and stored exactly as the clipboard import does")
    func imports() async throws {
        try makeSlackFolder(at: containerFolder)
        let safeStorage = FakeSafeStorage(.found(CookieFixture.password), terminal: terminal, scratch: scratch)
        let transport = TokenTransport([Self.alphaToken: Fake.authTestOK(team: "T01", user: "U01"),
                                        Self.betaToken: Fake.invalidAuth])

        let (results, error) = await run(safeStorage, transport)

        #expect(error == nil)
        #expect(results == [
            SlackImportResult(workspace: Fake.alpha, outcome: .imported),
            SlackImportResult(workspace: Fake.beta, outcome: .rejected("session invalid (invalid_auth)")),
        ])
        #expect(keychain.contents["SLACK_TOKEN_T01"] == Self.alphaToken)
        #expect(keychain.contents["SLACK_COOKIE_T01"] == CookieFixture.cookie)
        #expect(keychain.contents["SLACK_TOKEN_T02"] == nil)
        #expect(try await store.workspaces() == [Fake.alpha])
        #expect(transport.tokens == [Self.alphaToken, Self.betaToken])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "d=\(CookieFixture.cookie)" })
        #expect(terminal.lines.contains("Alpha (alpha, T01): imported"))
        #expect(terminal.lines.contains("Beta (beta, T02): rejected, session invalid (invalid_auth)"))
        #expect(SlackAuthImport.exitStatus(for: results ?? []) == 0)
        expectNoSecrets(error)
    }

    @Test("before Slack Safe Storage is read, the user is told to click Allow and not Always Allow")
    func promptsBeforeKeychain() async throws {
        try makeSlackFolder(at: containerFolder)
        let safeStorage = FakeSafeStorage(.found(CookieFixture.password), terminal: terminal, scratch: scratch)

        _ = await run(safeStorage, TokenTransport([:]))

        #expect(safeStorage.reads == 1)
        let before = try #require(safeStorage.linesBeforeRead)
        let prompt = try #require(before.last)
        #expect(prompt.contains("Slack Safe Storage"))
        #expect(prompt.contains("Allow"))
        #expect(prompt.contains("not Always Allow"))
        #expect(prompt.contains("180 s"))
    }

    @Test("the copies are made in a private temporary folder and deleted before the Keychain is asked")
    func copiesGoneBeforeKeychain() async throws {
        try makeSlackFolder(at: containerFolder)
        let safeStorage = FakeSafeStorage(.found(CookieFixture.password), terminal: terminal, scratch: scratch)

        _ = await run(safeStorage, TokenTransport([:]))

        #expect(safeStorage.scratchAtRead == [])
        #expect(scratchContents.isEmpty)
        let copied = try #require(terminal.lines.first { $0.hasPrefix("Copied Cookies and Local Storage/leveldb to ") })
        #expect(copied.contains(scratch.path))
    }

    @Test("the private temporary folder is created with permissions 0700")
    func scratchIsPrivate() throws {
        let folder = try SlackDesktopImport.makePrivateFolder(in: scratch)
        defer { try? FileManager.default.removeItem(at: folder) }

        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(folder.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL)
    }

    @Test("the second folder is used when the first does not exist; UTF-16 text and names holding a token are handled")
    func secondFolder() async throws {
        let config = #"{"teams":{"T01":{"id":"T01","domain":"alpha","name":"Alpha \#(Self.alphaToken)","token":"\#(Self.alphaToken)","user_id":"U01"},"T03":{"id":"T03"}}}"#
        try makeSlackFolder(at: plainFolder, config: Self.stored(config, utf16: true))
        let transport = TokenTransport([Self.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let (results, error) = await run(FakeSafeStorage(.found(CookieFixture.password), terminal: terminal), transport)

        #expect(error == nil)
        #expect(results?.map(\.outcome) == [.imported])
        #expect(terminal.lines.contains("Alpha <redacted> (alpha, T01): imported"))
        #expect(terminal.lines.contains { $0.contains("Skipped 1 team entry") })
        #expect(terminal.lines.contains { $0.contains(plainFolder.path) })
        expectNoSecrets(error)
    }

    // MARK: - The index

    /// spec: slack-credentials — "Keychain credential layout", scenario
    /// "Index that would not fit is refused before any write", through the
    /// desktop import.
    @Test("40 workspaces whose index would not fit: stops before Slack Safe Storage is read, with nothing written and no auth.test")
    func indexWouldNotFit() async throws {
        #expect(try await !IndexLimit.fits((1...40).map(ManyWorkspaces.workspace)))
        let teams = (1...40).map { #""\#(ManyWorkspaces.workspace($0).teamID)":"# + ManyWorkspaces.entry($0) }
        try makeSlackFolder(at: containerFolder, config: Self.stored(#"{"teams":{"# + teams.joined(separator: ",") + "}}"))
        let safeStorage = FakeSafeStorage(.found(CookieFixture.password), terminal: terminal, scratch: scratch)
        let transport = ManyWorkspaces.transport(1...40)

        let (results, error) = await run(safeStorage, transport)

        #expect(results == nil)
        let thrown = try #require(error as? SlackAuthCommandError, "\(String(describing: error))")
        #expect(thrown.message.contains("would list up to 40 workspaces"))
        #expect(thrown.message.contains("would not fit in one Keychain write"))
        #expect(thrown.message.contains("slack-all auth remove"))
        #expect(terminal.lines.contains { $0.hasPrefix("Read 40 workspace(s) from localConfig_v2") })
        #expect(safeStorage.reads == 0)
        #expect(keychain.writes.isEmpty)
        #expect(transport.requests.isEmpty)
        #expect(scratchContents.isEmpty)
        ManyWorkspaces.expectNoTokens(terminal.lines, error)
        expectNoSecrets(error)
    }

    // MARK: - Stopping

    enum Breakage: String, CaseIterable {
        case noCookiesFile, noLevelDB, noLocalConfig, deletedLocalConfig, malformedLocalConfig, damagedTable
        case noCookieRow, notSQLite, safeStorageAbsent, safeStorageTimedOut, safeStorageUnavailable, wrongPassword
    }

    func breakFolder(_ breakage: Breakage) throws -> (FakeSafeStorage, SlackDesktopImportError.Step) {
        let folder = containerFolder
        let leveldb = folder.appendingPathComponent("Local Storage/leveldb")
        let found = FakeSafeStorage(.found(CookieFixture.password), terminal: terminal, scratch: scratch)
        switch breakage {
        case .noCookiesFile:
            try makeSlackFolder(at: folder)
            try FileManager.default.removeItem(at: folder.appendingPathComponent("Cookies"))
            return (found, .copyData)
        case .noLevelDB:
            try makeSlackFolder(at: folder)
            try FileManager.default.removeItem(at: leveldb)
            return (found, .copyData)
        case .noLocalConfig:
            try makeSlackFolder(at: folder)
            try FileManager.default.removeItem(at: leveldb.appendingPathComponent("000005.ldb"))
            try FileManager.default.removeItem(at: leveldb.appendingPathComponent("000007.log"))
            return (found, .readLocalConfig)
        case .deletedLocalConfig:
            try makeSlackFolder(at: folder, config: nil)
            return (found, .readLocalConfig)
        case .malformedLocalConfig:
            try makeSlackFolder(at: folder, config: Self.stored("{\"teams\": \(Self.alphaToken)"))
            return (found, .readLocalConfig)
        case .damagedTable:
            try makeSlackFolder(at: folder)
            let table = leveldb.appendingPathComponent("000005.ldb")
            var bytes = Array(try Data(contentsOf: table))
            bytes[1] ^= 0xFF
            try Data(bytes).write(to: table)
            return (found, .readLocalConfig)
        case .noCookieRow:
            try makeSlackFolder(at: folder, cookies: [CookieDatabaseTests.Row(host: ".other.com", encrypted: CookieFixture.v24)])
            return (found, .readCookie)
        case .notSQLite:
            try makeSlackFolder(at: folder)
            try Data("not a database".utf8).write(to: folder.appendingPathComponent("Cookies"))
            return (found, .readCookie)
        case .safeStorageAbsent:
            try makeSlackFolder(at: folder)
            return (FakeSafeStorage(.absent, terminal: terminal, scratch: scratch), .readSafeStorage)
        case .safeStorageTimedOut:
            try makeSlackFolder(at: folder)
            return (FakeSafeStorage(.timedOut(after: 180), terminal: terminal, scratch: scratch), .readSafeStorage)
        case .safeStorageUnavailable:
            try makeSlackFolder(at: folder)
            return (FakeSafeStorage(.unavailable(reason: "security exited with status 51"), terminal: terminal, scratch: scratch),
                    .readSafeStorage)
        case .wrongPassword:
            try makeSlackFolder(at: folder)
            return (FakeSafeStorage(.found("not-the-test-password"), terminal: terminal, scratch: scratch), .decryptCookie)
        }
    }

    @Test("each failure stops with an error naming its step and suggesting slack-all auth import; nothing is stored and the copies are gone",
          arguments: Breakage.allCases)
    func failureNamesStep(breakage: Breakage) async throws {
        let (safeStorage, step) = try breakFolder(breakage)
        let transport = TokenTransport([Self.alphaToken: Fake.authTestOK(team: "T01", user: "U01")])

        let (results, error) = await run(safeStorage, transport)

        #expect(results == nil)
        let thrown = try #require(error as? SlackDesktopImportError, "\(String(describing: error))")
        #expect(thrown.step == step)
        #expect(thrown.description.contains("\"\(step.rawValue)\""))
        #expect(thrown.description.contains("slack-all auth import"))
        #expect(keychain.writes.isEmpty)
        #expect(transport.requests.isEmpty)
        #expect(scratchContents.isEmpty)
        let readsKeychain: Set<SlackDesktopImportError.Step> = [.readSafeStorage, .decryptCookie]
        #expect(safeStorage.reads == (readsKeychain.contains(step) ? 1 : 0))
        expectNoSecrets(error)
    }

    @Test("a copy that cannot be deleted is reported, naming the folder")
    func undeletableCopyIsReported() async throws {
        try makeSlackFolder(at: containerFolder)
        // When the copies exist, take away the right to delete them.
        terminal.onLine = { [scratch] line in
            if line.hasPrefix("Copied ") {
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.path)
            }
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        }

        _ = await run(FakeSafeStorage(.found(CookieFixture.password), terminal: terminal), TokenTransport([:]))

        let warning = try #require(terminal.lines.first { $0.hasPrefix("Warning: could not delete") })
        #expect(warning.contains(scratch.path))
    }
}

/// A Safe Storage reader that returns a fixed lookup, recording how often it
/// was asked, what the terminal had said by then, and what the temporary
/// folder held at that moment.
final class FakeSafeStorage: SlackSafeStorageReader, @unchecked Sendable {
    private let lock = NSLock()
    private let lookup: KeychainLookup
    private let terminal: RecordingTerminal
    private let scratch: URL?
    private var count = 0
    private var linesAtRead: [String]?
    private var scratchListing: [String]?

    let timeout: TimeInterval = 180

    init(_ lookup: KeychainLookup, terminal: RecordingTerminal, scratch: URL? = nil) {
        self.lookup = lookup
        self.terminal = terminal
        self.scratch = scratch
    }

    var reads: Int { lock.withLock { count } }
    var linesBeforeRead: [String]? { lock.withLock { linesAtRead } }
    var scratchAtRead: [String]? { lock.withLock { scratchListing } }

    func readPassword() async -> KeychainLookup {
        let lines = terminal.lines
        let listing = scratch.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }
        return lock.withLock {
            count += 1
            linesAtRead = lines
            scratchListing = listing
            return lookup
        }
    }
}

/// A terminal that records every line and can react to one as it is said.
final class RecordingTerminal: SlackAuthTerminal, @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    private var hook: (@Sendable (String) -> Void)?

    var lines: [String] { lock.withLock { said } }
    var onLine: (@Sendable (String) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func say(_ line: String) {
        let hook = lock.withLock { () -> (@Sendable (String) -> Void)? in
            said.append(line)
            return self.hook
        }
        hook?(line)
    }

    func waitForEnter() -> Bool { false }
}
