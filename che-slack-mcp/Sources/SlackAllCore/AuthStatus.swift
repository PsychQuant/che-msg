import Foundation
import SlackWebLib

/// `slack-all auth status`: each imported workspace and its `auth.test`
/// result, never a credential.
public struct SlackAuthStatus: Sendable {
    let store: SlackCredentialStore
    let client: SlackWebClient
    let terminal: any SlackAuthTerminal

    public init(store: SlackCredentialStore, client: SlackWebClient, terminal: any SlackAuthTerminal) {
        self.store = store
        self.client = client
        self.terminal = terminal
    }

    /// Prints one line per imported workspace: `valid`, the `auth.test`
    /// error class, or why its credential could not be read. Returns true
    /// when at least one workspace is imported and every one is valid.
    ///
    /// - Throws: `SlackCredentialError` when the index cannot be read.
    public func run() async throws -> Bool {
        let workspaces = try await store.workspaces()
        guard !workspaces.isEmpty else {
            terminal.say("No workspace is imported. \(SlackAuthText.importHint)")
            return false
        }
        var allValid = true
        for workspace in workspaces {
            let (valid, result) = try await check(workspace)
            allValid = allValid && valid
            terminal.say("\(SlackAuthText.label(workspace)): \(result)")
        }
        return allValid
    }

    /// Throws only `CancellationError`.
    private func check(_ workspace: SlackWorkspace) async throws -> (valid: Bool, result: String) {
        do {
            let credential = try await store.credential(for: workspace.teamID)
            let answer = try await client.authTest(credential: credential)
            guard answer.teamID == workspace.teamID else {
                return (false, "auth.test answered for team \(answer.teamID)")
            }
            return (true, "valid")
        } catch let error as SlackCredentialError {
            return (false, error.description)
        } catch let error as SlackError {
            return (false, SlackAuthText.describe(error))
        }
    }
}
