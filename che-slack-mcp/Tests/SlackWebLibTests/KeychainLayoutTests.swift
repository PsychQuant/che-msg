import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — Requirement "Keychain credential layout".
@Suite("Keychain credential layout")
struct KeychainLayoutTests {
    @Test("every item uses the Keychain account che-slack-mcp")
    func accountIsCheSlackMCP() {
        #expect(SlackKeychain.account == "che-slack-mcp")
    }

    @Test("the index lives in the service SLACK_WORKSPACES")
    func indexService() {
        #expect(SlackKeychain.workspacesService == "SLACK_WORKSPACES")
    }

    @Test("each workspace's token and cookie live in services named after its team id", arguments: [
        ("T01", "SLACK_TOKEN_T01", "SLACK_COOKIE_T01"),
        ("T02", "SLACK_TOKEN_T02", "SLACK_COOKIE_T02"),
    ])
    func perWorkspaceServices(teamID: String, token: String, cookie: String) {
        #expect(SlackKeychain.tokenService(teamID: teamID) == token)
        #expect(SlackKeychain.cookieService(teamID: teamID) == cookie)
    }

    @Test("an index entry decodes from team_id, domain, name and user_id")
    func indexEntryDecodes() throws {
        let json = #"""
        [{"team_id":"T01","domain":"alpha","name":"Alpha","user_id":"U01"},
         {"team_id":"T02","domain":"beta","name":"Beta","user_id":"U02"}]
        """#

        let decoded = try JSONDecoder().decode([SlackWorkspace].self, from: Data(json.utf8))

        #expect(decoded == [
            SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"),
            SlackWorkspace(teamID: "T02", domain: "beta", name: "Beta", userID: "U02"),
        ])
    }

    @Test("an encoded index entry has exactly the keys team_id, domain, name and user_id")
    func indexEntryEncodesFourKeys() throws {
        let data = try JSONEncoder().encode(SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01"))

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["team_id": "T01", "domain": "alpha", "name": "Alpha", "user_id": "U01"])
    }

    /// Expected values follow from the rule: team id or domain, ignoring
    /// case, whole string only. The name is never matched.
    @Test("a workspace matches its team id or its domain, ignoring case, and nothing else", arguments: [
        ("T01", true), ("t01", true), ("alpha", true), ("ALPHA", true),
        ("Alpha Team", false), ("alp", false), ("T0", false), (" alpha", false), ("alpha.slack.com", false), ("", false),
    ])
    func matching(query: String, expected: Bool) {
        let workspace = SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha Team", userID: "U01")

        #expect(workspace.matches(query) == expected)
    }
}
