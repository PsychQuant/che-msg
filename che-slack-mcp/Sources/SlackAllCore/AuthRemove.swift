import Foundation
import SlackWebLib

/// `slack-all auth remove <workspace>` (spec: slack-credentials, "Workspace
/// removal").
public struct SlackAuthRemove: Sendable {
    let store: SlackCredentialStore
    let terminal: any SlackAuthTerminal

    public init(store: SlackCredentialStore, terminal: any SlackAuthTerminal) {
        self.store = store
        self.terminal = terminal
    }

    /// Removes the workspace whose team id or domain is `query` (ignoring
    /// case): deletes its token, then its cookie, then drops it from the
    /// index. Items go first so a failure leaves the index still naming the
    /// workspace, and running the command again finishes the job (an item
    /// already gone is not an error); the reverse order could leave a
    /// credential in the Keychain that no index entry points to.
    ///
    /// - Throws: `SlackCredentialError` when the index cannot be read;
    ///   `SlackAuthCommandError` when nothing is imported, the query matches
    ///   no workspace or more than one (nothing is changed), or a delete or
    ///   the index write fails. The query is never repeated in a message.
    public func run(_ query: String) async throws {
        let workspaces = try await store.workspaces()
        guard !workspaces.isEmpty else {
            throw SlackAuthCommandError("No workspace is imported, so nothing was removed. \(SlackAuthText.importHint)")
        }
        let matches = workspaces.filter { $0.matches(query) }
        guard matches.count == 1, let target = matches.first else {
            let labels = { (list: [SlackWorkspace]) in list.map(SlackAuthText.label).joined(separator: ", ") }
            throw matches.isEmpty
                ? SlackAuthCommandError("No imported workspace has that team id or domain, so nothing was removed. "
                    + "Imported: \(labels(workspaces)).")
                : SlackAuthCommandError("That team id or domain matches more than one workspace, so nothing was removed. "
                    + "Matches: \(labels(matches)).")
        }
        let label = SlackAuthText.label(target)
        let again = "SLACK_WORKSPACES still lists \(label); run slack-all auth remove \(target.teamID) again."
        do {
            try await store.deleteCredential(teamID: target.teamID)
        } catch {
            throw SlackAuthCommandError("\(error) \(again)")
        }
        let token = SlackKeychain.tokenService(teamID: target.teamID)
        let cookie = SlackKeychain.cookieService(teamID: target.teamID)
        do {
            try await store.saveWorkspaces(workspaces.filter { $0.teamID != target.teamID })
        } catch {
            throw SlackAuthCommandError("Deleted \(token) and \(cookie), but \(error) \(again)")
        }
        terminal.say("Removed \(label): deleted \(token) and \(cookie) and removed it from SLACK_WORKSPACES.")
    }
}
