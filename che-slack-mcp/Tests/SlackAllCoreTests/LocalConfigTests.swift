import Foundation
import Testing
import SlackWebLib
@testable import SlackAllCore

/// `localConfig_v2`: which LevelDB key holds it, how its value is encoded,
/// and which workspaces it lists. All values are synthetic.
@Suite("localConfig_v2")
struct LocalConfigTests {
    static func key(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test("the key of app.slack.com's localConfig_v2 is recognised, with or without the Latin-1 marker",
          arguments: ["_https://app.slack.com\u{0}\u{1}localConfig_v2", "_https://app.slack.com\u{0}localConfig_v2"])
    func recognisedKey(text: String) {
        #expect(SlackLocalConfig.isKey(Self.key(text)))
    }

    @Test("keys of other origins, other names or without the separator are not", arguments: [
        "_https://evil.slack.com\u{0}\u{1}localConfig_v2",
        "_https://xyz.slack.com\u{0}\u{1}localConfig_v2",
        "_https://app.slack.org\u{0}\u{1}localConfig_v2",
        "_https://app.slack.com\u{2}\u{1}localConfig_v2",
        "_https://app.slack.com.evil\u{0}\u{1}localConfig_v2",
        "_https://app.slack.comlocalConfig_v2",
        "_https://app.slack.com\u{0}\u{1}localConfig_v2x",
        "_https://app.slack.com\u{0}\u{1}xlocalConfig_v2",
        "_https://app.slack.com\u{0}\u{1}\u{1}localConfig_v2",
        "_https://app.slack.com\u{0}\u{1}localConfig_v1",
        "META:https://app.slack.com",
        "localConfig_v2",
        "",
    ])
    func otherKeys(text: String) {
        #expect(!SlackLocalConfig.isKey(Self.key(text)))
    }

    @Test("a value marked 1 is Latin-1, one byte per character")
    func latin1() throws {
        #expect(try SlackLocalConfig.text(of: [1, 0x7B, 0x22, 0xE9, 0x22, 0x7D]) == "{\"é\"}")
    }

    @Test("a value marked 0 is UTF-16 little-endian")
    func utf16() throws {
        // "{名}" = U+007B U+540D U+007D; "😀" = D83D DE00.
        #expect(try SlackLocalConfig.text(of: [0, 0x7B, 0x00, 0x0D, 0x54, 0x7D, 0x00, 0x3D, 0xD8, 0x00, 0xDE]) == "{名}😀")
    }

    @Test("an empty value, an unknown marker, or broken UTF-16 throws",
          arguments: [[], [2, 0x41], [0, 0x41], [0, 0x00, 0xD8], [0, 0x00, 0xDC, 0x41, 0x00]] as [[UInt8]])
    func badValue(value: [UInt8]) {
        #expect(throws: DesktopFormatError.self) { try SlackLocalConfig.text(of: value) }
    }

    static let config = """
        {"teams":{
          "T02":{"id":"T02","domain":"beta","name":"Beta","token":"xoxc-test-beta","user_id":"U02","icon":{"x":1},"is_ent":false},
          "T01":{"id":"T01","domain":"alpha","name":"Alpha","token":"xoxc-test-alpha","user_id":"U01","unread":null},
          "T03":{"id":"T03","domain":"gamma","name":"Gamma","user_id":"U03"},
          "T04":{"id":"T04","domain":"delta","name":7,"token":"xoxc-test-delta","user_id":"U04"},
          "T05":"not an object"
        },"lastActiveTeamId":"T01","prefs":[1,2]}
        """

    @Test("each team with string id, domain, name, token and user_id is a candidate, sorted by team id; the others are counted")
    func candidates() throws {
        let (candidates, skipped) = try SlackLocalConfig.candidates(from: Self.config)

        #expect(candidates.map(\.workspace) == [
            SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"),
            SlackWorkspace(teamID: "T02", domain: "beta", name: "Beta", userID: "U02"),
        ])
        #expect(candidates.map(\.token) == ["xoxc-test-alpha", "xoxc-test-beta"])
        #expect(skipped == 3)
    }

    @Test("text that is not JSON with a teams object, or lists no complete team, throws without quoting it", arguments: [
        "", "not json xoxc-test-leak", "[]", #"{"teams":[{"token":"xoxc-test-leak"}]}"#, #"{"other":{}}"#,
        #"{"teams":{}}"#, #"{"teams":{"T01":{"id":"T01","token":"xoxc-test-leak"}}}"#,
    ])
    func malformed(json: String) {
        #expect {
            try SlackLocalConfig.candidates(from: json)
        } throws: { error in
            guard let error = error as? DesktopFormatError else { return false }
            return !error.reason.contains("xoxc-test-leak")
        }
    }
}
