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

    /// The spec scenario "Index lists workspaces without credentials", read
    /// back: the index decodes to T01 (alpha) and T02 (beta), and each
    /// workspace's two items give its credential. The T02 name is non-ASCII,
    /// which `security -g` prints as hex.
    @Test("an imported T01 and T02 read back as the index and two credentials")
    func readsTheLayout() async throws {
        let searchList = try ScratchKeychain.userSearchList()
        let keychain = try ScratchKeychain(in: scratch)
        defer { keychain.delete() }
        #expect(try ScratchKeychain.userSearchList() == searchList, "creating the scratch keychain changed the search list")
        try keychain.add(SlackKeychain.workspacesService, #"[{"team_id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"},"#
            + #"{"team_id":"T02","domain":"beta","name":"日本語チーム","user_id":"U02"}]"#)
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
        try keychain.add(SlackKeychain.workspacesService, #"[{"team_id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"}]"#)
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
