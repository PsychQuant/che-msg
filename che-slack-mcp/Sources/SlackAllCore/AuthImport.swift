import Foundation
import SlackWebLib

/// One workspace's line in the import report.
public struct SlackImportResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `auth.test` succeeded and both items were written.
        case imported
        /// Not verified, so nothing was written: the reason is the error
        /// class from `auth.test`, or why the credential could not be stored.
        case rejected(String)
        /// Verified, but writing its items failed or may have failed.
        case notStored(String)
    }

    public let workspace: SlackWorkspace
    public let outcome: Outcome

    public init(workspace: SlackWorkspace, outcome: Outcome) {
        self.workspace = workspace
        self.outcome = outcome
    }
}

/// `slack-all auth import` (spec: slack-credentials, "Clipboard import").
///
/// Where the spec is silent:
/// - The index is read first, so a broken `SLACK_WORKSPACES` stops the
///   import before the user copies anything.
/// - A first read that is rejected, or input that ends at the cookie prompt,
///   clears the clipboard only when it holds `xox` (it may hold a token);
///   anything else the user had copied is left alone. The second read is
///   always cleared, before it is checked.
/// - The cookie is taken without surrounding whitespace or a leading `d=`.
/// - A workspace whose team id or token the Keychain layout cannot hold is
///   rejected without calling `auth.test`; so is one whose `auth.test`
///   answers for a different team id.
/// - A verified workspace whose items could not be written is reported
///   `notStored` and left out of the index (an earlier entry for it is kept).
/// - The index is merged by team id: a re-imported workspace's entry is
///   replaced in place, new ones are appended, others stay.
public struct SlackAuthImport: Sendable {
    /// Pasted into the console of `app.slack.com`. Safari's console has
    /// `copy()` (task 1.1), so no `navigator.clipboard.writeText` variant.
    public static let consoleCommand = "copy(JSON.stringify(Object.values(JSON.parse(localStorage.localConfig_v2).teams)"
        + ".map(t=>({id:t.id,domain:t.domain,name:t.name,token:t.token,user_id:t.user_id}))))"

    let store: SlackCredentialStore
    let client: SlackWebClient
    let clipboard: any SlackClipboard
    let terminal: any SlackAuthTerminal

    public init(store: SlackCredentialStore, client: SlackWebClient,
                clipboard: any SlackClipboard, terminal: any SlackAuthTerminal) {
        self.store = store
        self.client = client
        self.clipboard = clipboard
        self.terminal = terminal
    }

    static let inputEnded = SlackAuthCommandError("Input ended before Enter was pressed; nothing was imported.")

    /// Runs the two copy steps, verifies and stores each workspace, prints
    /// one line per workspace, and returns the results.
    ///
    /// - Throws: `SlackCredentialError` when the index cannot be read;
    ///   `SlackAuthCommandError` when input ends, a read is not what the step
    ///   asked for, or the index cannot be written after an import.
    public func run() async throws -> [SlackImportResult] {
        let existing = try await store.workspaces()

        terminal.say("Step 1 of 2: open https://app.slack.com in the browser where you are signed in to Slack, "
            + "open its JavaScript console (Safari: Develop > Show JavaScript Console), paste this line and press Return:")
        terminal.say(Self.consoleCommand)
        terminal.say("It copies the workspaces signed in on that browser. Then press Enter here.")
        guard terminal.waitForEnter() else { throw Self.inputEnded }
        let first = clipboard.text()
        let candidates: [ImportCandidate]
        do {
            candidates = try ClipboardImport.candidates(from: first)
        } catch {
            clearIfToken(first)
            throw error
        }

        // Names come from Slack's data and are not trusted to be free of
        // credentials: every line from here on is scrubbed of the tokens,
        // and once it is read, of the cookie.
        var redact = Redaction(secrets: candidates.map(\.token))
        let names = candidates.map(\.workspace.name).joined(separator: ", ")
        terminal.say(redact("Read \(candidates.count) workspace(s): \(names)."))
        terminal.say("Step 2 of 2: in the developer tools' Storage tab, open Cookies for app.slack.com, "
            + "copy the value of the cookie named d, then press Enter here.")
        guard terminal.waitForEnter() else {
            clearIfToken(clipboard.text())
            throw Self.inputEnded
        }
        let second = clipboard.text()
        clearClipboard()
        let cookie = try ClipboardImport.cookie(from: second)
        redact = Redaction(secrets: redact.secrets + [cookie])

        var results: [SlackImportResult] = []
        for candidate in candidates {
            let result = try await verifyAndSave(candidate, cookie: cookie)
            results.append(result)
            terminal.say(redact(Self.line(for: result)))
        }

        let imported = results.filter { $0.outcome == .imported }.map(\.workspace)
        guard !imported.isEmpty else { return results }
        do {
            try await store.saveWorkspaces(Self.merge(existing, imported))
        } catch {
            let labels = imported.map(SlackAuthText.label).joined(separator: ", ")
            throw SlackAuthCommandError(redact("\(error) The credentials of \(labels) were written, but SLACK_WORKSPACES "
                + "does not list them; run slack-all auth import again."))
        }
        return results
    }

    /// 0 when at least one workspace was imported, else 1.
    public static func exitStatus(for results: [SlackImportResult]) -> Int32 {
        results.contains { $0.outcome == .imported } ? 0 : 1
    }

    /// Checks, verifies, then stores one workspace. Throws only
    /// `CancellationError`.
    private func verifyAndSave(_ candidate: ImportCandidate, cookie: String) async throws -> SlackImportResult {
        let workspace = candidate.workspace
        let credential = SlackCredential(teamID: workspace.teamID, token: candidate.token, cookie: cookie)
        do {
            try store.check(credential)
        } catch {
            return SlackImportResult(workspace: workspace, outcome: .rejected("\(error)"))
        }
        do {
            let answer = try await client.authTest(credential: credential)
            guard answer.teamID == workspace.teamID else {
                return SlackImportResult(workspace: workspace, outcome: .rejected("auth.test answered for team \(answer.teamID)"))
            }
        } catch let error as SlackError {
            return SlackImportResult(workspace: workspace, outcome: .rejected(SlackAuthText.describe(error)))
        }
        do {
            try await store.save(credential)
        } catch {
            return SlackImportResult(workspace: workspace, outcome: .notStored("\(error)"))
        }
        return SlackImportResult(workspace: workspace, outcome: .imported)
    }

    static func line(for result: SlackImportResult) -> String {
        let label = SlackAuthText.label(result.workspace)
        switch result.outcome {
        case .imported: return "\(label): imported"
        case .rejected(let reason): return "\(label): rejected, \(reason)"
        case .notStored(let reason): return "\(label): not stored, \(reason)"
        }
    }

    /// `existing` with each of `imported` replacing the entry with its team
    /// id, or appended when there is none.
    static func merge(_ existing: [SlackWorkspace], _ imported: [SlackWorkspace]) -> [SlackWorkspace] {
        imported.reduce(into: existing) { merged, workspace in
            if let index = merged.firstIndex(where: { $0.teamID == workspace.teamID }) {
                merged[index] = workspace
            } else {
                merged.append(workspace)
            }
        }
    }

    /// Clears the clipboard when `text`, what it was last read as, may hold
    /// a token.
    private func clearIfToken(_ text: String?) {
        if text?.contains("xox") == true { clearClipboard() }
    }

    /// Clears the clipboard and says whether that worked.
    private func clearClipboard() {
        clipboard.clear()
        if clipboard.text() == nil {
            terminal.say("Cleared the clipboard.")
        } else {
            terminal.say("Warning: the clipboard could not be cleared; copy something else over it.")
        }
    }
}

/// Replaces every occurrence of a secret with `<redacted>`, longest first so
/// a secret that contains another is replaced whole.
struct Redaction: Sendable {
    let secrets: [String]

    init(secrets: [String]) {
        self.secrets = Array(Set(secrets.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }

    func callAsFunction(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: SlackCredential.redacted) }
    }
}
