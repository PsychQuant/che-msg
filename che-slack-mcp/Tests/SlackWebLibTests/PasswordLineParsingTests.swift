import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — "Credential lookup is bounded": the value is
/// read from the `password:` line `security find-generic-password -g` writes
/// to stderr. `security` quotes a printable ASCII value and prints any other
/// value as hex, followed by an escaped quoted copy when the value has a
/// printable ASCII character (measured on macOS 27 for che-telegram-all-mcp,
/// PsychQuant/che-msg#49).
@Suite("Reading the password line of security -g")
struct PasswordLineParsingTests {
    static func parse(_ stderr: String) -> SecurityCLIKeychainReader.PasswordLine {
        SecurityCLIKeychainReader.parsePasswordLine(Data(stderr.utf8))
    }

    static let readable: [(String, String)] = [
        ("password: \"xoxc-1-2-3\"\n", "xoxc-1-2-3"),
        ("keychain: \"/x\"\npassword: \"after-attributes\"\n", "after-attributes"),
        ("password: \"636166c3a9\"\n", "636166c3a9"),
        ("password: \"end\"\"\n", "end\""),
        ("password: \n", ""),
        ("password: 0x636166C3A9  \"caf\\303\\251\"\n", "café"),
        ("password: 0x636166c3a9  \"caf\\303\\251\"\n", "café"),
        ("password: 0x6C696E65310A6C696E6532  \"line1\\012line2\"\n", "line1\nline2"),
        ("password: 0xE697A5E69CACE8AA9E \n", "日本語"),
        ("password: 0xE697A5E69CACE8AA9E\n", "日本語"),
    ]

    @Test("readable lines give the stored value", arguments: readable)
    func readableLine(stderr: String, expected: String) {
        #expect(Self.parse(stderr) == .value(expected))
    }

    @Test("a leading byte order mark is kept")
    func byteOrderMarkIsKept() throws {
        guard case .value(let value) = Self.parse("password: 0xEFBBBF626F6D \n") else {
            Issue.record("expected a value")
            return
        }
        #expect(value.unicodeScalars.first == "\u{FEFF}")
        #expect(value.unicodeScalars.count == 4)
    }

    /// Each case pairs a line with a fragment of its content that the reason
    /// must not repeat.
    static let unreadable: [(String, String)] = [
        ("something else\n", "something"),
        ("password: xoxc-unquoted\n", "xoxc-unquoted"),
        ("password: \"unterminated\n", "unterminated"),
        ("password:glued\n", "glued"),
        ("password: \"cut-short\"", "cut-short"),
        ("password: 0x636166", "636166"),
        ("password: 0xFF  \"\\377\"\n", "FF"),
        ("password: 0x61ZZ  \"aZZ\"\n", "ZZ"),
        ("password: 0x616  \"a\"\n", "616"),
        ("password: 0x  \"\"\n", "\"\""),
        ("password: 0x61\"a\"\n", "61"),
    ]

    @Test("unreadable lines give a reason that does not repeat the content", arguments: unreadable)
    func unreadableLine(stderr: String, fragment: String) {
        guard case .unreadable(let reason) = Self.parse(stderr) else {
            Issue.record("expected unreadable, got \(Self.parse(stderr))")
            return
        }
        #expect(!reason.contains(fragment))
    }
}
