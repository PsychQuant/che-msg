import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — "Keychain credential layout" read and written
/// through `SlackCredentialStore`, "Credential lookup is bounded" for how a
/// missing or unreadable item is reported, and "Keychain write keeps values
/// off argv" for what the store refuses. An in-memory Keychain stands in.
/// Base64 literals were computed by hand with `/usr/bin/base64`.
@Suite("Reading workspaces and credentials")
struct CredentialStoreTests {
    static let token = "xoxc-fake-token-1111"
    static let cookie = "xoxd-fake%2Fcookie"
    /// base64 of `[{"team_id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"},`
    /// `{"team_id":"T02","domain":"beta","name":"Beta","user_id":"U02"}]`.
    static let index = "W3sidGVhbV9pZCI6IlQwMSIsImRvbWFpbiI6ImFscGhhIiwibmFtZSI6IkFscGhhIiwidXNlcl9pZCI6IlUwMSJ9LHsidGVhbV9p"
        + "ZCI6IlQwMiIsImRvbWFpbiI6ImJldGEiLCJuYW1lIjoiQmV0YSIsInVzZXJfaWQiOiJVMDIifV0="

    /// Fails the test with the thrown value unless it is a `SlackCredentialError`.
    static func error(_ body: () async throws -> some Any) async -> SlackCredentialError? {
        do {
            _ = try await body()
            return nil
        } catch let error as SlackCredentialError {
            return error
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
            return nil
        }
    }

    // MARK: - The index

    @Test("the index gives the imported workspaces in stored order")
    func indexListsWorkspaces() async throws {
        let keychain = FakeKeychain(["SLACK_WORKSPACES": .found(Self.index)])

        let workspaces = try await SlackCredentialStore(reader: keychain).workspaces()

        #expect(workspaces == [
            SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"),
            SlackWorkspace(teamID: "T02", domain: "beta", name: "Beta", userID: "U02"),
        ])
        #expect(keychain.reads == ["SLACK_WORKSPACES"])
    }

    /// "Nothing imported" is an empty list, whether the index item was never
    /// written or was emptied by removing every workspace; only a Keychain
    /// that cannot be read throws.
    @Test("no index, or an empty one (base64 of []), means nothing imported: an empty list", arguments: [
        KeychainLookup.absent, .found("W10="),
    ])
    func nothingImportedIsEmpty(index: KeychainLookup) async throws {
        let keychain = FakeKeychain(["SLACK_WORKSPACES": index])

        #expect(try await SlackCredentialStore(reader: keychain).workspaces() == [])
        #expect(keychain.reads == ["SLACK_WORKSPACES"])
    }

    @Test("an index that cannot be read throws an error naming SLACK_WORKSPACES", arguments: [
        (KeychainLookup.timedOut(after: 10), SlackCredentialError.timedOut(service: "SLACK_WORKSPACES", after: 10)),
        (.unavailable(reason: "exited with status 51"), .unavailable(service: "SLACK_WORKSPACES", reason: "exited with status 51")),
    ])
    func unreadableIndexThrows(index: KeychainLookup, expected: SlackCredentialError) async throws {
        let keychain = FakeKeychain(["SLACK_WORKSPACES": index])

        let error = try #require(await Self.error { try await SlackCredentialStore(reader: keychain).workspaces() })

        #expect(error == expected)
        #expect(error.service == "SLACK_WORKSPACES")
        #expect(error.description.contains("SLACK_WORKSPACES"))
    }

    static let notBase64 = "is not valid base64"
    static let notJSON = "is not valid JSON"
    static let notWorkspaces = "is not a JSON array of objects with string team_id, domain, name and user_id"

    /// Each case: the stored index, a fragment the error must not repeat,
    /// and the fixed reason expected. Foundation's own decoding errors quote
    /// characters of the input, so the reason is pinned exactly. Past the
    /// first five, each stored value is the base64 of the JSON in its
    /// comment.
    static let malformedIndexes: [(String, String, String)] = [
        // An index stored as plain JSON, as before base64.
        (#"[{"team_id":"T01","domain":"leakeddomain","name":"A","user_id":"U01"}]"#, "leakeddomain", notBase64),
        ("xoxc-leaked", "xoxc-leaked", notBase64),          // '-' is not in the standard alphabet
        ("W10", "W10", notBase64),                          // base64 of [] without its padding
        ("W1 0=", "W1 0", notBase64),
        ("W10=\n", "W10", notBase64),
        // not json xoxc-leaked
        ("bm90IGpzb24geG94Yy1sZWFrZWQ=", "xoxc-leaked", notJSON),
        // [{"team_id":"T01","domain":"d","name":"n","user_id":"U"}] trailing-leaked
        ("W3sidGVhbV9pZCI6IlQwMSIsImRvbWFpbiI6ImQiLCJuYW1lIjoibiIsInVzZXJfaWQiOiJVIn1dIHRyYWlsaW5nLWxlYWtlZA==",
         "trailing-leaked", notJSON),
        // "xoxc-leaked"
        ("InhveGMtbGVha2VkIg==", "xoxc-leaked", notWorkspaces),
        // {"team_id":"T01","domain":"leakeddomain","name":"A","user_id":"U01"}
        ("eyJ0ZWFtX2lkIjoiVDAxIiwiZG9tYWluIjoibGVha2VkZG9tYWluIiwibmFtZSI6IkEiLCJ1c2VyX2lkIjoiVTAxIn0=",
         "leakeddomain", notWorkspaces),
        // [{"team_id":"T01","domain":"leakeddomain"}]
        ("W3sidGVhbV9pZCI6IlQwMSIsImRvbWFpbiI6ImxlYWtlZGRvbWFpbiJ9XQ==", "leakeddomain", notWorkspaces),
        // [{"team_id":1,"domain":"leakeddomain","name":"A","user_id":"U01"}]
        ("W3sidGVhbV9pZCI6MSwiZG9tYWluIjoibGVha2VkZG9tYWluIiwibmFtZSI6IkEiLCJ1c2VyX2lkIjoiVTAxIn1d", "leakeddomain", notWorkspaces),
        // [null]
        ("W251bGxd", "null", notWorkspaces),
    ]

    @Test("an index that is not base64 of a workspace array throws malformedIndex naming SLACK_WORKSPACES without its content",
          arguments: malformedIndexes)
    func malformedIndexThrows(stored: String, fragment: String, reason: String) async throws {
        let keychain = FakeKeychain(["SLACK_WORKSPACES": .found(stored)])

        let error = try #require(await Self.error { try await SlackCredentialStore(reader: keychain).workspaces() })

        #expect(error == .malformedIndex(reason: reason))
        #expect(error.service == "SLACK_WORKSPACES")
        #expect(error.description.contains("SLACK_WORKSPACES"))
        #expect(!error.description.contains(fragment))
    }

    // MARK: - One workspace's credential

    @Test("a workspace's credential is its SLACK_TOKEN_ and SLACK_COOKIE_ items")
    func credentialReadsTokenAndCookie() async throws {
        let keychain = FakeKeychain([
            "SLACK_TOKEN_T01": .found(Self.token),
            "SLACK_COOKIE_T01": .found(Self.cookie),
            "SLACK_TOKEN_T02": .found("xoxc-other"),
        ])

        let credential = try await SlackCredentialStore(reader: keychain).credential(for: "T01")

        #expect(credential == SlackCredential(teamID: "T01", token: Self.token, cookie: Self.cookie))
        #expect(keychain.reads == ["SLACK_TOKEN_T01", "SLACK_COOKIE_T01"])
    }

    /// The spec scenario "Missing token is reported by name".
    @Test("SLACK_WORKSPACES lists T01 but SLACK_TOKEN_T01 does not exist: absent, naming SLACK_TOKEN_T01")
    func missingTokenIsNamed() async throws {
        let keychain = FakeKeychain([
            "SLACK_WORKSPACES": .found(Self.index),
            "SLACK_COOKIE_T01": .found(Self.cookie),
        ])
        let store = SlackCredentialStore(reader: keychain)
        #expect(try await store.workspaces().map(\.teamID).contains("T01"))

        let error = try #require(await Self.error { try await store.credential(for: "T01") })

        #expect(error == .absent(service: "SLACK_TOKEN_T01"))
        #expect(error.description.contains("SLACK_TOKEN_T01"))
        #expect(!error.description.contains(Self.cookie))
    }

    @Test("a missing cookie is absent, naming SLACK_COOKIE_T01 and not the token")
    func missingCookieIsNamed() async throws {
        let keychain = FakeKeychain(["SLACK_TOKEN_T01": .found(Self.token)])

        let error = try #require(await Self.error { try await SlackCredentialStore(reader: keychain).credential(for: "T01") })

        #expect(error == .absent(service: "SLACK_COOKIE_T01"))
        #expect(error.description.contains("SLACK_COOKIE_T01"))
        #expect(!error.description.contains(Self.token))
    }

    static let unreadableItems: [(String, KeychainLookup, SlackCredentialError)] = [
        ("SLACK_TOKEN_T01", .timedOut(after: 10), .timedOut(service: "SLACK_TOKEN_T01", after: 10)),
        ("SLACK_COOKIE_T01", .timedOut(after: 0.5), .timedOut(service: "SLACK_COOKIE_T01", after: 0.5)),
        ("SLACK_TOKEN_T01", .unavailable(reason: "exited with status 51"),
         .unavailable(service: "SLACK_TOKEN_T01", reason: "exited with status 51")),
        ("SLACK_COOKIE_T01", .unavailable(reason: "printed no password line"),
         .unavailable(service: "SLACK_COOKIE_T01", reason: "printed no password line")),
    ]

    @Test("a token or cookie that cannot be read throws an error naming its service", arguments: unreadableItems)
    func unreadableItemIsNamed(service: String, lookup: KeychainLookup, expected: SlackCredentialError) async throws {
        var items: [String: KeychainLookup] = ["SLACK_TOKEN_T01": .found(Self.token), "SLACK_COOKIE_T01": .found(Self.cookie)]
        items[service] = lookup

        let error = try #require(await Self.error { try await SlackCredentialStore(reader: FakeKeychain(items)).credential(for: "T01") })

        #expect(error == expected)
        #expect(error.service == service)
        #expect(error.description.contains(service))
        #expect(!error.description.contains(Self.token))
        #expect(!error.description.contains(Self.cookie))
    }

    @Test("each error describes itself with its service", arguments: [
        (SlackCredentialError.absent(service: "SLACK_TOKEN_T01"), "SLACK_TOKEN_T01 is not stored"),
        (.timedOut(service: "SLACK_COOKIE_T01", after: 10), "within 10 s"),
        (.unavailable(service: "SLACK_TOKEN_T01", reason: "exited with status 51"), "exited with status 51"),
    ])
    func descriptions(error: SlackCredentialError, phrase: String) {
        #expect(error.description.contains(phrase))
        #expect(error.localizedDescription == error.description)
    }

    // MARK: - No copy of the value

    @Test("every call reads the Keychain again: a changed token is seen at once")
    func nothingIsCached() async throws {
        let keychain = FakeKeychain(["SLACK_TOKEN_T01": .found("xoxc-first"), "SLACK_COOKIE_T01": .found(Self.cookie)])
        let store = SlackCredentialStore(reader: keychain)

        let first = try await store.credential(for: "T01")
        keychain.set("SLACK_TOKEN_T01", .found("xoxc-second"))
        let second = try await store.credential(for: "T01")

        #expect(first.token == "xoxc-first")
        #expect(second.token == "xoxc-second")
        #expect(keychain.reads.filter { $0 == "SLACK_TOKEN_T01" }.count == 2)
    }

    @Test("production reads through security with a 10 second limit")
    func productionReader() throws {
        let reader = try #require(SlackCredentialStore().reader as? SecurityCLIKeychainReader)

        #expect(reader.executable.path == "/usr/bin/security")
        #expect(reader.keychainPath == nil)
        #expect(reader.timeout == 10)
    }

    // MARK: - Writing

    @Test("the index is written as base64 of the JSON array, keys sorted, in the given order")
    func savesIndexAsBase64() async throws {
        let keychain = FakeKeychain([:])

        try await SlackCredentialStore(reader: keychain, writer: keychain).saveWorkspaces([
            SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"),
            SlackWorkspace(teamID: "T02", domain: "beta", name: "Beta", userID: "U02"),
        ])

        // base64 of [{"domain":"alpha","name":"Alpha","team_id":"T01","user_id":"U01"},
        //            {"domain":"beta","name":"Beta","team_id":"T02","user_id":"U02"}]
        #expect(keychain.writes == [FakeKeychain.Write(service: "SLACK_WORKSPACES", value:
            "W3siZG9tYWluIjoiYWxwaGEiLCJuYW1lIjoiQWxwaGEiLCJ0ZWFtX2lkIjoiVDAxIiwidXNlcl9pZCI6IlUwMSJ9LHsiZG9tYWlu"
            + "IjoiYmV0YSIsIm5hbWUiOiJCZXRhIiwidGVhbV9pZCI6IlQwMiIsInVzZXJfaWQiOiJVMDIifV0=")])
    }

    /// A name in any script survives: base64 carries its UTF-8 bytes through
    /// the write path's character check.
    @Test("a non-ASCII workspace name is written as the base64 of its UTF-8 and reads back the same")
    func nonASCIINameRoundTrips() async throws {
        let keychain = FakeKeychain([:])
        let store = SlackCredentialStore(reader: keychain, writer: keychain)
        let workspaces = [SlackWorkspace(teamID: "T02", domain: "beta", name: "日本語チーム", userID: "U02")]

        try await store.saveWorkspaces(workspaces)
        let readBack = try await store.workspaces()

        // base64 of [{"domain":"beta","name":"日本語チーム","team_id":"T02","user_id":"U02"}]
        #expect(keychain.writes.map(\.value)
                == ["W3siZG9tYWluIjoiYmV0YSIsIm5hbWUiOiLml6XmnKzoqp7jg4Hjg7zjg6AiLCJ0ZWFtX2lkIjoiVDAyIiwidXNlcl9pZCI6IlUwMiJ9XQ=="])
        #expect(readBack == workspaces)
    }

    @Test("an empty workspace list is written as W10=, the base64 of []")
    func savesEmptyIndex() async throws {
        let keychain = FakeKeychain([:])

        try await SlackCredentialStore(reader: keychain, writer: keychain).saveWorkspaces([])

        #expect(keychain.writes == [FakeKeychain.Write(service: "SLACK_WORKSPACES", value: "W10=")])
    }

    @Test("a credential is written as its token, then its cookie")
    func savesTokenThenCookie() async throws {
        let keychain = FakeKeychain([:])

        try await SlackCredentialStore(reader: keychain, writer: keychain)
            .save(SlackCredential(teamID: "T01", token: Self.token, cookie: Self.cookie))

        #expect(keychain.writes == [
            FakeKeychain.Write(service: "SLACK_TOKEN_T01", value: Self.token),
            FakeKeychain.Write(service: "SLACK_COOKIE_T01", value: Self.cookie),
        ])
    }

    /// The spec scenarios "Team id with a quote is refused" and "Value with a
    /// quote is refused": both items are checked before either is written,
    /// so a refused cookie never leaves a new token beside an old cookie.
    @Test("a credential that fails a check is refused, naming the service, and nothing is written", arguments: [
        (SlackCredential(teamID: #"T01"x"#, token: token, cookie: cookie),
         SlackKeychainWriteError.refused(service: #"SLACK_TOKEN_T01"x"#, reason: .teamID)),
        (SlackCredential(teamID: "T01", token: token, cookie: #"xoxd-a"b"#),
         .refused(service: "SLACK_COOKIE_T01", reason: .valueCharacters)),
        (SlackCredential(teamID: "T01", token: "", cookie: cookie),
         .refused(service: "SLACK_TOKEN_T01", reason: .emptyValue)),
    ])
    func refusedCredentialWritesNothing(credential: SlackCredential, expected: SlackKeychainWriteError) async throws {
        let keychain = FakeKeychain([:])

        let error = await KeychainWriterTests.error {
            try await SlackCredentialStore(reader: keychain, writer: keychain).save(credential)
        }

        #expect(error == expected)
        #expect(error?.description.contains(expected.service) == true)
        #expect(keychain.writes.isEmpty)
    }

    @Test("a token write that fails stops the save: the error names SLACK_TOKEN_T01 and no cookie is written")
    func failedTokenWriteStops() async throws {
        let keychain = FakeKeychain([:])
        let failure = SlackKeychainWriteError.failed(service: "SLACK_TOKEN_T01", reason: "security -i exited with status 2")
        keychain.failWrites(to: "SLACK_TOKEN_T01", with: failure)

        let error = await KeychainWriterTests.error {
            try await SlackCredentialStore(reader: keychain, writer: keychain)
                .save(SlackCredential(teamID: "T01", token: Self.token, cookie: Self.cookie))
        }

        #expect(error == failure)
        #expect(keychain.writes.isEmpty)
    }

    @Test("production writes through security -i with a 10 second limit and no keychain path")
    func productionWriter() throws {
        let writer = try #require(SlackCredentialStore().writer as? SecurityCLIKeychainWriter)

        #expect(writer.executable.path == "/usr/bin/security")
        #expect(writer.keychainPath == nil)
        #expect(writer.timeout == 10)
    }
}

/// An in-memory Keychain: answers each service from `items` (absent when
/// missing) and records every service read, in order. A write stores the
/// value and is recorded; it makes no check of its own, so a test sees
/// whatever the store lets through.
final class FakeKeychain: KeychainItemReader, KeychainItemWriter, @unchecked Sendable {
    struct Write: Equatable {
        let service: String
        let value: String
    }

    private let lock = NSLock()
    private var items: [String: KeychainLookup]
    private var log: [String] = []
    private var writeLog: [Write] = []
    private var failures: [String: SlackKeychainWriteError] = [:]

    init(_ items: [String: KeychainLookup]) { self.items = items }

    var reads: [String] { lock.withLock { log } }

    /// Every successful write, in order.
    var writes: [Write] { lock.withLock { writeLog } }

    func set(_ service: String, _ lookup: KeychainLookup) { lock.withLock { items[service] = lookup } }

    /// Makes every later write to `service` throw `error` and store nothing.
    func failWrites(to service: String, with error: SlackKeychainWriteError) { lock.withLock { failures[service] = error } }

    func write(service: String, value: String) async throws {
        try lock.withLock {
            if let error = failures[service] { throw error }
            writeLog.append(Write(service: service, value: value))
            items[service] = .found(value)
        }
    }

    func read(service: String) async -> KeychainLookup {
        lock.withLock {
            log.append(service)
            return items[service] ?? .absent
        }
    }
}
