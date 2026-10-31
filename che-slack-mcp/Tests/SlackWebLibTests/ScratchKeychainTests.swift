import Foundation
import Testing
@testable import SlackWebLib

/// End to end with the real `/usr/bin/security` against a scratch keychain
/// file created in a fresh temporary directory and passed by path to every
/// call. These tests never read the user's keychains and never change the
/// search list (`list-keychains -s`, `default-keychain -s` are never run);
/// each checks the user search list is the same before, during and after.
/// Serialized so one test's keychain cannot appear in another's check.
@Suite("Keychain layout read from a scratch keychain file", .serialized,
       .enabled(if: FileManager.default.isExecutableFile(atPath: ScratchKeychain.security)))
struct ScratchKeychainTests {
    let scratch: ScratchDirectory

    init() throws { scratch = try ScratchDirectory() }

    /// Items seeded by argv (synthetic values), read through the store: the
    /// index decodes to T01 (alpha) and T02 (beta), and each workspace's two
    /// items give its credential. The T02 name is non-ASCII; base64 keeps
    /// the stored value ASCII.
    @Test("an imported T01 and T02 read back as the index and two credentials")
    func readsTheLayout() async throws {
        let searchList = try ScratchKeychain.userSearchList()
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        #expect(try ScratchKeychain.userSearchList() == searchList, "creating the scratch keychain changed the search list")
        // base64 of [{"team_id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"},
        //            {"team_id":"T02","domain":"beta","name":"日本語チーム","user_id":"U02"}]
        try keychain.add(SlackKeychain.workspacesService,
                         "W3sidGVhbV9pZCI6IlQwMSIsImRvbWFpbiI6ImFscGhhIiwibmFtZSI6IkFscGhhIiwidXNlcl9pZCI6IlUwMSJ9LHsidGVh"
                         + "bV9pZCI6IlQwMiIsImRvbWFpbiI6ImJldGEiLCJuYW1lIjoi5pel5pys6Kqe44OB44O844OgIiwidXNlcl9pZCI6IlUwMiJ9XQ==")
        try keychain.add("SLACK_TOKEN_T01", "xoxc-fake-t01")
        try keychain.add("SLACK_COOKIE_T01", "xoxd-fake%2Bt01")
        try keychain.add("SLACK_TOKEN_T02", "xoxc-fake-t02")
        try keychain.add("SLACK_COOKIE_T02", "xoxd-fake%2Ft02=")
        let store = SlackCredentialStore(reader: SecurityCLIKeychainReader(keychainPath: keychain.path))

        let workspaces = try await store.workspaces()
        let t01 = try await store.credential(for: "T01")
        let t02 = try await store.credential(for: "T02")

        #expect(workspaces == [
            SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"),
            SlackWorkspace(teamID: "T02", domain: "beta", name: "日本語チーム", userID: "U02"),
        ])
        #expect(t01 == SlackCredential(teamID: "T01", token: "xoxc-fake-t01", cookie: "xoxd-fake%2Bt01"))
        #expect(t02 == SlackCredential(teamID: "T02", token: "xoxc-fake-t02", cookie: "xoxd-fake%2Ft02="))
        keychain.delete()
        #expect(try ScratchKeychain.userSearchList() == searchList, "the search list changed")
    }

    /// The spec scenario "Missing token is reported by name".
    @Test("SLACK_WORKSPACES lists T01 but SLACK_TOKEN_T01 does not exist: absent, naming SLACK_TOKEN_T01")
    func missingTokenIsNamed() async throws {
        let searchList = try ScratchKeychain.userSearchList()
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        // base64 of [{"team_id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"}]
        try keychain.add(SlackKeychain.workspacesService,
                         "W3sidGVhbV9pZCI6IlQwMSIsImRvbWFpbiI6ImFscGhhIiwibmFtZSI6IkFscGhhIiwidXNlcl9pZCI6IlUwMSJ9XQ==")
        try keychain.add("SLACK_COOKIE_T01", "xoxd-fake-cookie")
        let reader = SecurityCLIKeychainReader(keychainPath: keychain.path)
        let store = SlackCredentialStore(reader: reader)

        let listed = try await store.workspaces().map(\.teamID)
        let lookup = await reader.read(service: "SLACK_TOKEN_T01")
        let error = await CredentialStoreTests.error { try await store.credential(for: "T01") }

        #expect(listed == ["T01"])
        #expect(lookup == .absent)
        #expect(error == .absent(service: "SLACK_TOKEN_T01"))
        #expect(error?.description.contains("SLACK_TOKEN_T01") == true)
        #expect(error?.description.contains("xoxd-fake-cookie") == false)
        keychain.delete()
        #expect(try ScratchKeychain.userSearchList() == searchList, "the search list changed")
    }

    @Test("no index item means nothing imported, and a re-imported token is read at once")
    func nothingImportedThenNoCache() async throws {
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        let store = SlackCredentialStore(reader: SecurityCLIKeychainReader(keychainPath: keychain.path))
        try keychain.add("SLACK_TOKEN_T01", "xoxc-first")
        try keychain.add("SLACK_COOKIE_T01", "xoxd-cookie")

        let none = try await store.workspaces()
        let first = try await store.credential(for: "T01")
        try keychain.add("SLACK_TOKEN_T01", "xoxc-second")
        let second = try await store.credential(for: "T01")

        #expect(none == [])
        #expect(first.token == "xoxc-first")
        #expect(second.token == "xoxc-second")
    }

    /// The spec scenario "Index lists workspaces without credentials", written
    /// through the store with the real `security -i`: the raw index item
    /// base64-decodes (here, independently of the store) to a JSON array of
    /// T01/alpha and T02/beta, and the four token and cookie items exist.
    @Test("T01 (alpha) and T02 (beta) imported: SLACK_WORKSPACES base64-decodes to both, and four items exist")
    func importedLayout() async throws {
        let searchList = try ScratchKeychain.userSearchList()
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        let reader = SecurityCLIKeychainReader(keychainPath: keychain.path)
        let store = SlackCredentialStore(reader: reader, writer: SecurityCLIKeychainWriter(keychainPath: keychain.path))
        let workspaces = [
            SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"),
            SlackWorkspace(teamID: "T02", domain: "beta", name: "日本語チーム", userID: "U02"),
        ]

        try await store.saveWorkspaces(workspaces)
        try await store.save(SlackCredential(teamID: "T01", token: "xoxc-fake-t01", cookie: "xoxd-fake%2Bt01"))
        try await store.save(SlackCredential(teamID: "T02", token: "xoxc-fake-t02", cookie: "xoxd-fake%2Ft02="))

        let stored = try #require(await reader.read(service: "SLACK_WORKSPACES").value)
        let json = try #require(Data(base64Encoded: stored))
        let objects = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: String]])
        #expect(objects.map { [$0["team_id"], $0["domain"]] } == [["T01", "alpha"], ["T02", "beta"]])
        #expect(objects.last?["name"] == "日本語チーム")
        #expect(objects.allSatisfy { Set($0.keys) == ["team_id", "domain", "name", "user_id"] })
        #expect(await reader.read(service: "SLACK_TOKEN_T01") == .found("xoxc-fake-t01"))
        #expect(await reader.read(service: "SLACK_COOKIE_T01") == .found("xoxd-fake%2Bt01"))
        #expect(await reader.read(service: "SLACK_TOKEN_T02") == .found("xoxc-fake-t02"))
        #expect(await reader.read(service: "SLACK_COOKIE_T02") == .found("xoxd-fake%2Ft02="))
        #expect(try await store.workspaces() == workspaces)
        keychain.delete()
        #expect(try ScratchKeychain.userSearchList() == searchList, "the search list changed")
    }

    /// The spec scenario "Value with a quote is refused", against a keychain
    /// that already holds T01's items: both keep their values.
    @Test("a cookie containing a quote is refused naming SLACK_COOKIE_T01, and T01's items are unchanged")
    func quotedCookieChangesNothing() async throws {
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        try keychain.add("SLACK_TOKEN_T01", "xoxc-old")
        try keychain.add("SLACK_COOKIE_T01", "xoxd-old")
        let reader = SecurityCLIKeychainReader(keychainPath: keychain.path)
        let store = SlackCredentialStore(reader: reader, writer: SecurityCLIKeychainWriter(keychainPath: keychain.path))

        let error = await KeychainWriterTests.error {
            try await store.save(SlackCredential(teamID: "T01", token: "xoxc-new", cookie: #"xoxd-new"x"#))
        }

        #expect(error == .refused(service: "SLACK_COOKIE_T01", reason: .valueCharacters))
        #expect(error?.description.contains("SLACK_COOKIE_T01") == true)
        #expect(await reader.read(service: "SLACK_TOKEN_T01") == .found("xoxc-old"))
        #expect(await reader.read(service: "SLACK_COOKIE_T01") == .found("xoxd-old"))
    }

    /// The spec scenario "Team id with a quote is refused": afterwards the
    /// scratch keychain holds no item at all for the account (an attribute
    /// lookup by account alone exits 44).
    @Test("a token for team id T01\"x is refused naming its service, and no item is created")
    func quotedTeamIDCreatesNothing() async throws {
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        let store = SlackCredentialStore(reader: SecurityCLIKeychainReader(keychainPath: keychain.path),
                                         writer: SecurityCLIKeychainWriter(keychainPath: keychain.path))

        let error = await KeychainWriterTests.error {
            try await store.save(SlackCredential(teamID: #"T01"x"#, token: "xoxc-new", cookie: "xoxd-new"))
        }

        #expect(error == .refused(service: #"SLACK_TOKEN_T01"x"#, reason: .teamID))
        #expect(keychain.itemCount() == 0)
    }

    /// The real `security -i` against the scratch file: the value comes back
    /// exactly, and `-U` replaces it on the second write.
    @Test("a value written through security -i reads back exactly, and a second write replaces it")
    func writeReadsBack() async throws {
        let searchList = try ScratchKeychain.userSearchList()
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        let writer = SecurityCLIKeychainWriter(keychainPath: keychain.path)
        let reader = SecurityCLIKeychainReader(keychainPath: keychain.path)

        try await writer.write(service: "SLACK_TOKEN_T01", value: "xoxc-TEST%2Fab_c.d-e+f/g=")
        let first = await reader.read(service: "SLACK_TOKEN_T01")
        try await writer.write(service: "SLACK_TOKEN_T01", value: "xoxc-second")
        let second = await reader.read(service: "SLACK_TOKEN_T01")

        #expect(first == .found("xoxc-TEST%2Fab_c.d-e+f/g="))
        #expect(second == .found("xoxc-second"))
        keychain.delete()
        #expect(try ScratchKeychain.userSearchList() == searchList, "the search list changed")
    }

    /// The real `security delete-generic-password` against the scratch file:
    /// the deleted item reads back absent, the other workspace's item is
    /// unchanged, and deleting it again is not an error (security exits 44).
    @Test("a deleted item reads back absent, others stay, and a second delete is not an error")
    func deleteRemovesOneItem() async throws {
        let searchList = try ScratchKeychain.userSearchList()
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        try keychain.add("SLACK_TOKEN_T01", "xoxc-fake-t01")
        try keychain.add("SLACK_TOKEN_T02", "xoxc-fake-t02")
        let writer = SecurityCLIKeychainWriter(keychainPath: keychain.path)
        let reader = SecurityCLIKeychainReader(keychainPath: keychain.path)

        try await writer.delete(service: "SLACK_TOKEN_T01")
        let deleted = await reader.read(service: "SLACK_TOKEN_T01")
        let kept = await reader.read(service: "SLACK_TOKEN_T02")
        try await writer.delete(service: "SLACK_TOKEN_T01")

        #expect(deleted == .absent)
        #expect(kept == .found("xoxc-fake-t02"))
        keychain.delete()
        #expect(try ScratchKeychain.userSearchList() == searchList, "the search list changed")
    }

    /// The real reader with a stand-in tool that never answers: the store
    /// reports the timeout naming the item it was reading.
    @Test("a token lookup that does not finish is reported as timed out, naming SLACK_TOKEN_T01")
    func tokenLookupTimesOut() async throws {
        let reader = SecurityCLIKeychainReader(executable: try scratch.fakeSecurity("exec sleep 30"),
                                               keychainPath: scratch.path("unused.keychain-db"), timeout: 0.5)
        let started = Date()

        let error = await CredentialStoreTests.error { try await SlackCredentialStore(reader: reader).credential(for: "T01") }

        #expect(error == .timedOut(service: "SLACK_TOKEN_T01", after: 0.5))
        #expect(error?.description.contains("SLACK_TOKEN_T01") == true)
        #expect(Date().timeIntervalSince(started) < 3)
    }
}

/// A keychain file in a scratch directory, created and unlocked with a random
/// password and deleted by path. It is never added to the search list.
struct ScratchKeychain {
    static let security = "/usr/bin/security"
    let path: String

    init(in directory: ScratchDirectory) throws {
        path = directory.path("scratch-\(UUID().uuidString).keychain-db")
        let password = "scratch-\(UUID().uuidString)"
        try run(Self.security, ["create-keychain", "-p", password, path])
        do {
            try run(Self.security, ["unlock-keychain", "-p", password, path])
        } catch {
            delete()
            throw error
        }
    }

    /// Adds or replaces a synthetic item under the account `che-slack-mcp`.
    func add(_ service: String, _ fakeValue: String) throws {
        try run(Self.security, ["add-generic-password", "-U", "-a", SlackKeychain.account, "-s", service, "-w", fakeValue, path])
    }

    /// How many items for the account `che-slack-mcp` the file holds,
    /// counted from attribute-only lookups (no `-g`, so no value is read):
    /// 0 when `find-generic-password -a` exits 44, else at least 1.
    func itemCount() -> Int {
        do {
            try run(Self.security, ["find-generic-password", "-a", SlackKeychain.account, path])
            return 1
        } catch let failed as ToolFailed where failed.status == 44 {
            return 0
        } catch {
            return -1
        }
    }

    /// Deletes the file by path; deleting twice is harmless.
    func delete() {
        guard FileManager.default.fileExists(atPath: path) else { return }
        _ = try? run(Self.security, ["delete-keychain", path])
    }

    /// The user search list, read only.
    static func userSearchList() throws -> String {
        try run(security, ["list-keychains", "-d", "user"])
    }
}
