import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — "Keychain write keeps values off argv", the
/// checks made before anything runs. Values here are synthetic.
@Suite("Checks before a Keychain write")
struct KeychainWritePolicyTests {
    /// The thrown write error, or nil when nothing was thrown. Any other
    /// error type fails the test.
    static func refusal(_ body: () throws -> Void) -> SlackKeychainWriteError? {
        do {
            try body()
            return nil
        } catch let error as SlackKeychainWriteError {
            return error
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
            return nil
        }
    }

    // MARK: - Accepted

    static let accepted: [(String, String)] = [
        ("SLACK_TOKEN_T01", "xoxc-TEST%2Fab_c.d-e+f/g="),           // every punctuation the spec allows
        ("SLACK_COOKIE_T01", "xoxd-ABCxyz0189"),
        ("SLACK_WORKSPACES", "W10="),
        ("SLACK_TOKEN_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", "a"),     // 32-character team id, 1-character value
        ("SLACK_COOKIE_0", "-"),
    ]

    @Test("a che-slack-mcp service with a value from the allowed set passes", arguments: accepted)
    func acceptsAllowedItems(service: String, value: String) {
        #expect(Self.refusal { try KeychainWritePolicy.check(service: service, value: value) } == nil)
        #expect(Self.refusal { try SecurityCLIKeychainWriter().check(service: service, value: value) } == nil)
    }

    // MARK: - Refused values

    /// Each case breaks `security -i`'s quoting or is outside the spec's set.
    static let badValues: [String] = [
        #"xoxd-a"b"#, "xoxd a", #"xoxd\a"#, "xoxd\na", "xoxd\ra", "xoxd\ta", "xoxd\u{0}a", "xoxd'a", "xoxd#a",
        "xoxd$a", "xoxd;a", "xoxd&a", "xoxd*a", "xoxdéa", "xoxde\u{301}a", "ｘoxd",
    ]

    /// The spec scenario "Value with a quote is refused" is the first case.
    @Test("a value with a character outside A-Z a-z 0-9 - _ . % + / = is refused, naming the service", arguments: badValues)
    func refusesValueCharacters(value: String) {
        let error = Self.refusal { try KeychainWritePolicy.check(service: "SLACK_COOKIE_T01", value: value) }

        #expect(error == .refused(service: "SLACK_COOKIE_T01", reason: .valueCharacters))
    }

    @Test("an empty value is refused, naming the service")
    func refusesEmptyValue() {
        let error = Self.refusal { try KeychainWritePolicy.check(service: "SLACK_TOKEN_T01", value: "") }

        #expect(error == .refused(service: "SLACK_TOKEN_T01", reason: .emptyValue))
    }

    // MARK: - Refused team ids and services

    /// The spec scenario "Team id with a quote is refused" is the first case.
    static let badTeamIDs: [String] = [
        #"T01"x"#, "", "t01", "T01 X", "T-01", "T_01", "T01\nX", "Ｔ01",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456",   // 33 characters
    ]

    @Test("a team id that is not 1 to 32 characters from A-Z 0-9 is refused, naming the service", arguments: badTeamIDs)
    func refusesTeamID(teamID: String) {
        let token = SlackKeychain.tokenService(teamID: teamID)
        let cookie = SlackKeychain.cookieService(teamID: teamID)

        #expect(Self.refusal { try KeychainWritePolicy.check(service: token, value: "xoxc-1") }
                == .refused(service: token, reason: .teamID))
        #expect(Self.refusal { try KeychainWritePolicy.check(service: cookie, value: "xoxd-1") }
                == .refused(service: cookie, reason: .teamID))
    }

    @Test("a service outside the layout is refused", arguments: [
        "SLACK_OTHER_T01", "slack_token_T01", "SLACK_TOKEN", "SLACK_WORKSPACES2", "SLACK_WORKSPACES_T01", "", "login",
    ])
    func refusesUnknownService(service: String) {
        #expect(Self.refusal { try KeychainWritePolicy.check(service: service, value: "W10=") }
                == .refused(service: service, reason: .unknownService))
    }

    // MARK: - The command line

    @Test("the command line is the spec's add-generic-password line, with the keychain path only when one is given")
    func commandLine() {
        #expect(SecurityCLIKeychainWriter().commandLine(service: "SLACK_TOKEN_T01", value: "xoxc-1")
                == #"add-generic-password -U -a che-slack-mcp -s SLACK_TOKEN_T01 -w "xoxc-1""#)
        #expect(SecurityCLIKeychainWriter(keychainPath: "/tmp/x y.keychain-db").commandLine(service: "SLACK_TOKEN_T01", value: "xoxc-1")
                == #"add-generic-password -U -a che-slack-mcp -s SLACK_TOKEN_T01 -w "xoxc-1" "/tmp/x y.keychain-db""#)
    }

    @Test("a keychain path with a quote, backslash or control character is refused", arguments: [
        #"/tmp/a"b.keychain-db"#, #"/tmp/a\b.keychain-db"#, "/tmp/a\nb.keychain-db", "/tmp/a\u{7f}b.keychain-db", "",
    ])
    func refusesKeychainPath(path: String) {
        let writer = SecurityCLIKeychainWriter(keychainPath: path)

        #expect(Self.refusal { try writer.check(service: "SLACK_TOKEN_T01", value: "xoxc-1") }
                == .refused(service: "SLACK_TOKEN_T01", reason: .keychainPath))
    }

    /// `security -i` reads 4095 bytes at a time: a longer line runs its
    /// remainder as a second command. `add-generic-password -U -a
    /// che-slack-mcp -s SLACK_TOKEN_T01 -w ""` is 65 bytes, so a value of
    /// 4029 bytes makes the longest allowed line, 4094 bytes.
    @Test("a command line longer than 4094 bytes is refused; 4094 bytes passes")
    func refusesLongLine() {
        let writer = SecurityCLIKeychainWriter()
        let longest = String(repeating: "a", count: 4029)

        #expect(writer.commandLine(service: "SLACK_TOKEN_T01", value: longest).utf8.count == 4094)
        #expect(Self.refusal { try writer.check(service: "SLACK_TOKEN_T01", value: longest) } == nil)
        #expect(Self.refusal { try writer.check(service: "SLACK_TOKEN_T01", value: longest + "a") }
                == .refused(service: "SLACK_TOKEN_T01", reason: .lineTooLong))
    }

    // MARK: - Descriptions

    @Test("each error names its service, says what happened to the item, and never shows the value", arguments: [
        (SlackKeychainWriteError.refused(service: "SLACK_COOKIE_T01", reason: .valueCharacters),
         "Refused to write Keychain item SLACK_COOKIE_T01: the value contains a character outside A-Z a-z 0-9 - _ . % + / =; nothing was written."),
        (.failed(service: "SLACK_TOKEN_T01", reason: "security -i exited with status 2"),
         "Writing Keychain item SLACK_TOKEN_T01 may have failed: security -i exited with status 2."),
        (.timedOut(service: "SLACK_WORKSPACES", after: 10),
         "Writing Keychain item SLACK_WORKSPACES did not finish within 10 s; it may or may not have been written."),
    ])
    func descriptions(error: SlackKeychainWriteError, expected: String) {
        #expect(error.description == expected)
        #expect(error.localizedDescription == expected)
    }
}
