import Foundation
import SlackWebLib

/// One workspace as the console command copies it. Holds a token, so its
/// description shows only the team id.
struct ImportCandidate: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let workspace: SlackWorkspace
    let token: String

    var description: String { "ImportCandidate(teamID: \(workspace.teamID), token: \(SlackCredential.redacted))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["workspace": workspace, "token": SlackCredential.redacted], displayStyle: .struct)
    }
}

/// Reading what the user copied. Every error is a fixed phrase: nothing read
/// from the clipboard is ever quoted.
enum ClipboardImport {
    private struct Entry: Decodable {
        let id: String
        let domain: String
        let name: String
        let token: String
        let user_id: String
    }

    /// The workspaces in the first read: a non-empty JSON array of objects
    /// with string `id`, `domain`, `name`, `token` and `user_id` (other keys
    /// are ignored). Anything else, including an empty array, throws.
    static func candidates(from text: String?) throws -> [ImportCandidate] {
        let again = " Nothing was imported; run slack-all auth import again and paste the command into the console of app.slack.com."
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SlackAuthCommandError("The clipboard holds no text." + again)
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(text.utf8)) else {
            throw SlackAuthCommandError("The clipboard does not hold the workspace list from the console command "
                + "(a JSON array of objects with string id, domain, name, token and user_id)." + again)
        }
        guard !entries.isEmpty else {
            throw SlackAuthCommandError("The clipboard holds an empty workspace list: no workspace is signed in on app.slack.com." + again)
        }
        return entries.map {
            ImportCandidate(workspace: SlackWorkspace(teamID: $0.id, domain: $0.domain, name: $0.name, userID: $0.user_id),
                            token: $0.token)
        }
    }

    /// The `d` cookie value in the second read, without surrounding
    /// whitespace or a leading `d=` (in case the whole `name=value` pair was
    /// copied). It must be one or more characters the Keychain write path
    /// accepts; anything else, such as the workspace list still on the
    /// clipboard, throws before any `auth.test`.
    static func cookie(from text: String?) throws -> String {
        var value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("d=") { value.removeFirst(2) }
        let again = " Nothing was imported; run slack-all auth import again."
        guard !value.isEmpty else {
            throw SlackAuthCommandError("The clipboard holds no d cookie value." + again)
        }
        guard SlackKeychain.acceptsValue(value) else {
            throw SlackAuthCommandError("The clipboard does not hold a d cookie value: it contains characters other than "
                + "A-Z a-z 0-9 - _ . % + / =." + again)
        }
        return value
    }
}
