import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — "Keychain credential layout": before an import
/// writes a token or cookie, it checks that the merged `SLACK_WORKSPACES`
/// value can be written in one write, as "Keychain write keeps values off
/// argv" defines it: one `security -i` line of at most 4094 bytes. This is
/// the store's half: `checkWorkspaces` puts exactly the value
/// `saveWorkspaces` would write through the writer's own check and starts
/// nothing. The last test measures how many workspaces fit, the numbers the
/// READMEs give.
@Suite("Checking that the index fits one Keychain write")
struct IndexCapacityTests {
    let scratch: ScratchDirectory

    init() throws { scratch = try ScratchDirectory() }

    /// The production writer's checks; the executable cannot exist, and
    /// checking starts nothing anyway.
    static let productionChecks = SecurityCLIKeychainWriter(executable: URL(fileURLWithPath: "/dev/null/security"))

    /// `text`, then digits of `number`, zero-padded to `length` characters.
    static func field(_ text: String, _ number: Int, length: Int) -> String {
        let digits = String(number)
        return text + String(repeating: "0", count: max(0, length - text.count - digits.count)) + digits
    }

    /// Workspace `number`, its ids, domain and name of the given lengths
    /// (ASCII; the name is `name` repeated instead, when one is given).
    static func workspace(_ number: Int, ids: Int = 11, domain: Int = 15, nameLength: Int = 20,
                          name: String? = nil) -> SlackWorkspace {
        SlackWorkspace(teamID: field("T", number, length: ids), domain: field("d", number, length: domain),
                       name: name.map { String(repeating: $0, count: nameLength) } ?? field("N", number, length: nameLength),
                       userID: field("U", number, length: ids))
    }

    /// The JSON bytes of the index the store writes for `workspaces`.
    static func jsonBytes(_ workspaces: [SlackWorkspace]) throws -> Int {
        try #require(Data(base64Encoded: SlackCredentialStore.indexValue(workspaces))).count
    }

    static func renamed(_ workspace: SlackWorkspace, _ name: String) -> SlackWorkspace {
        SlackWorkspace(teamID: workspace.teamID, domain: workspace.domain, name: name, userID: workspace.userID)
    }

    static let lineTooLong = SlackKeychainWriteError.refused(service: "SLACK_WORKSPACES", reason: .lineTooLong)

    // MARK: - The check

    @Test("checkWorkspaces checks, with the writer's own check, exactly the value saveWorkspaces writes")
    func checksWhatIsWritten() async throws {
        let writer = RecordingWriter()
        let store = SlackCredentialStore(reader: FakeKeychain([:]), writer: writer)
        let lists: [[SlackWorkspace]] = [
            [],
            [Self.workspace(1)],
            [Self.workspace(1), Self.workspace(2, name: "日本語"), Self.renamed(Self.workspace(3), #"a/b "q" \ é"#)],
        ]

        for list in lists {
            try store.checkWorkspaces(list)
            try await store.saveWorkspaces(list)
        }

        #expect(writer.checks.count == lists.count)
        #expect(writer.checks == writer.writes)
        #expect(writer.checks.allSatisfy { $0.service == "SLACK_WORKSPACES" })
    }

    @Test("an index whose security -i line would be longer than 4094 bytes is refused, naming SLACK_WORKSPACES; checking starts no process")
    func refusesLongIndexWithoutStarting() throws {
        let marker = scratch.path("started")
        let writer = SecurityCLIKeychainWriter(executable: try scratch.fakeSecurity("touch '\(marker)'"))
        let store = SlackCredentialStore(reader: FakeKeychain([:]), writer: writer)
        let many = (1...40).map { Self.workspace($0) }

        #expect(throws: Self.lineTooLong) { try store.checkWorkspaces(many) }
        #expect(throws: Never.self) { try store.checkWorkspaces(Array(many.prefix(2))) }
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    /// `add-generic-password -U -a che-slack-mcp -s SLACK_WORKSPACES -w ""` is
    /// 66 bytes, leaving 4028 for the base64, a multiple of 4: the longest
    /// JSON that fits makes a line of exactly 4094 bytes.
    @Test("an index whose line is exactly 4094 bytes passes; one byte more of JSON is refused")
    func exactBoundary() throws {
        let writer = Self.productionChecks
        let store = SlackCredentialStore(reader: FakeKeychain([:]), writer: writer)
        let overhead = writer.commandLine(service: SlackKeychain.workspacesService, value: "").utf8.count
        let longestJSON = (SecurityCLIKeychainWriter.maxLineBytes - overhead) / 4 * 3
        var workspaces = (1...3).map { Self.workspace($0) }
        let padding = longestJSON - (try Self.jsonBytes(workspaces))
        workspaces[2] = Self.renamed(workspaces[2], workspaces[2].name + String(repeating: "x", count: padding))

        #expect(try Self.jsonBytes(workspaces) == longestJSON)
        let line = writer.commandLine(service: SlackKeychain.workspacesService, value: try SlackCredentialStore.indexValue(workspaces))
        #expect(line.utf8.count == SecurityCLIKeychainWriter.maxLineBytes)
        #expect(throws: Never.self) { try store.checkWorkspaces(workspaces) }

        workspaces[2] = Self.renamed(workspaces[2], workspaces[2].name + "x")
        #expect(throws: Self.lineTooLong) { try store.checkWorkspaces(workspaces) }
    }

    @Test("an entry's byte count is its object in the index's JSON: n entries take 2 + their sum + n - 1 bytes")
    func entryByteCount() throws {
        let alpha = SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01")
        let entries = [alpha, Self.workspace(2, name: "日本語"), Self.renamed(Self.workspace(3), #"a/b "q" \ é"#)]

        #expect(try SlackCredentialStore.indexEntryByteCount(alpha)
                == #"{"domain":"alpha","name":"Alpha","team_id":"T01","user_id":"U01"}"#.utf8.count)
        let sizes = try entries.map(SlackCredentialStore.indexEntryByteCount)
        #expect(try Self.jsonBytes(entries) == 2 + sizes.reduce(0, +) + entries.count - 1)
    }

    // MARK: - Capacity

    /// The entry shapes the READMEs name. Typical: an 11-character team id
    /// and user id (Slack's current length), a 15-character domain and a
    /// 20-character name. Short: 9-character ids (`T0123ABCD`), an
    /// 8-character domain and a 10-character name. Long: a 21-character
    /// domain and a 50-character name. CJK: a name of 20 Chinese or
    /// Japanese characters, 3 UTF-8 bytes each.
    enum Shape: String, CaseIterable {
        case short, typical, long, cjk

        func workspace(_ number: Int) -> SlackWorkspace {
            switch self {
            case .short: return IndexCapacityTests.workspace(number, ids: 9, domain: 8, nameLength: 10)
            case .typical: return IndexCapacityTests.workspace(number)
            case .long: return IndexCapacityTests.workspace(number, domain: 21, nameLength: 50)
            case .cjk: return IndexCapacityTests.workspace(number, name: "團")
            }
        }
    }

    @Test("how many workspaces fit one write: 35 short, 28 typical, 21 long, 20 with a CJK name", arguments: [
        (Shape.short, 35), (.typical, 28), (.long, 21), (.cjk, 20),
    ])
    func capacity(shape: Shape, expected: Int) throws {
        let store = SlackCredentialStore(reader: FakeKeychain([:]), writer: Self.productionChecks)
        let fits = { (count: Int) in (try? store.checkWorkspaces((1...count).map(shape.workspace))) != nil }

        #expect(fits(expected))
        #expect(!fits(expected + 1))
    }
}

/// A writer that records every check and every write, and refuses nothing.
final class RecordingWriter: KeychainItemWriter, @unchecked Sendable {
    struct Item: Equatable {
        let service: String
        let value: String
    }

    private let lock = NSLock()
    private var checked: [Item] = []
    private var written: [Item] = []

    var checks: [Item] { lock.withLock { checked } }
    var writes: [Item] { lock.withLock { written } }

    func check(service: String, value: String) throws {
        lock.withLock { checked.append(Item(service: service, value: value)) }
    }

    func write(service: String, value: String) async throws {
        lock.withLock { written.append(Item(service: service, value: value)) }
    }

    func delete(service: String) async throws {}
}
