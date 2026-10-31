import Foundation
import SlackWebLib

/// The system clipboard, as `slack-all auth import` uses it. The executable
/// provides the AppKit one; tests provide a fake, so no test ever touches
/// the user's clipboard.
public protocol SlackClipboard: Sendable {
    /// The clipboard's text, or nil when it holds none.
    func text() -> String?
    /// Empties the clipboard.
    func clear()
}

/// The terminal the `auth` commands talk to.
public protocol SlackAuthTerminal: Sendable {
    /// Writes one line to standard output.
    func say(_ line: String)
    /// Waits for the user to press Enter. False when input has ended.
    func waitForEnter() -> Bool
}

/// A failed `auth` command. The message is written by this module from
/// fixed phrases, workspace names, team ids and Keychain service names; it
/// never holds a token or a cookie.
public struct SlackAuthCommandError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Shared wording for the `auth` commands.
enum SlackAuthText {
    /// `Alpha (alpha, T01)`.
    static func label(_ workspace: SlackWorkspace) -> String {
        "\(workspace.name) (\(workspace.domain), \(workspace.teamID))"
    }

    /// The error's class and Slack's code, e.g. `session invalid
    /// (invalid_auth)`. `SlackError` never holds a credential: the client
    /// scrubs both values out of text that came from outside.
    static func describe(_ error: SlackError) -> String {
        switch error {
        case let .sessionInvalid(_, code): return "session invalid (\(code))"
        case let .rateLimited(seconds): return "rate limited (retry after \(seconds) s)"
        case let .enterpriseRestricted(_, code): return "enterprise restricted (\(code))"
        case let .slackError(code): return "Slack error (\(code))"
        case let .network(description): return "network error (\(description))"
        }
    }

    static let importHint = "Run slack-all auth import to import a workspace."
}
