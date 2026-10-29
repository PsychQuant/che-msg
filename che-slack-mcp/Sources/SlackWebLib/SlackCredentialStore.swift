import Foundation

/// Why a Keychain item could not be used. Every case names the item's
/// service (spec: slack-credentials, "Credential lookup is bounded": a
/// missing item is reported naming the service, not the value); no case
/// holds an item's content.
public enum SlackCredentialError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The item does not exist (or is empty).
    case absent(service: String)
    /// Reading the item was still running after `after` seconds and was stopped.
    case timedOut(service: String, after: TimeInterval)
    /// `security` failed or printed something that is not a value.
    case unavailable(service: String, reason: String)
    /// `SLACK_WORKSPACES` holds something other than the base64 of a JSON
    /// array of workspace objects. The reason is a fixed phrase, never the
    /// content.
    case malformedIndex(reason: String)

    public var service: String {
        switch self {
        case .absent(let service), .timedOut(let service, _), .unavailable(let service, _):
            return service
        case .malformedIndex:
            return SlackKeychain.workspacesService
        }
    }

    public var description: String {
        let item = "Keychain item \(service)"
        switch self {
        case .absent:
            return "\(item) is not stored (account \(SlackKeychain.account))."
        case .timedOut(_, let seconds):
            return "Reading \(item) did not finish within \(formatSeconds(seconds)) s."
        case .unavailable(_, let reason):
            return "Reading \(item) failed: \(reason)."
        case .malformedIndex(let reason):
            return "\(item) \(reason)."
        }
    }

    public var errorDescription: String? { description }
}

/// Reads and writes the per-workspace credential layout described on
/// `SlackKeychain`. It holds no value between calls: every call reads the
/// Keychain again, so a re-import is seen at once and nothing outlives the
/// call that needed it.
public struct SlackCredentialStore: Sendable {
    public let reader: any KeychainItemReader
    public let writer: any KeychainItemWriter

    public init(reader: any KeychainItemReader = SecurityCLIKeychainReader(),
                writer: any KeychainItemWriter = SecurityCLIKeychainWriter()) {
        self.reader = reader
        self.writer = writer
    }

    /// The workspaces in `SLACK_WORKSPACES`, in stored order.
    ///
    /// Nothing imported is an empty list: the index item does not exist (no
    /// import has run) or holds `[]` (every workspace was removed). Callers
    /// tell "nothing imported" from "Keychain broken" by empty list versus
    /// thrown error.
    ///
    /// - Throws: `SlackCredentialError` naming `SLACK_WORKSPACES` when the
    ///   item cannot be read (`timedOut`, `unavailable`), or is not standard
    ///   base64 with padding of a JSON array of objects with string
    ///   `team_id`, `domain`, `name` and `user_id` (`malformedIndex`).
    public func workspaces() async throws -> [SlackWorkspace] {
        let service = SlackKeychain.workspacesService
        let stored: String
        do {
            stored = try await value(of: service)
        } catch SlackCredentialError.absent {
            return []
        }
        // Strict: no whitespace, no URL-safe alphabet, padding required.
        guard let json = Data(base64Encoded: stored) else {
            throw SlackCredentialError.malformedIndex(reason: "is not valid base64")
        }
        do {
            return try JSONDecoder().decode([SlackWorkspace].self, from: json)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            throw SlackCredentialError.malformedIndex(reason: "is not valid JSON")
        } catch {
            // DecodingError descriptions can quote the content; use a fixed phrase.
            throw SlackCredentialError.malformedIndex(
                reason: "is not a JSON array of objects with string team_id, domain, name and user_id")
        }
    }

    /// The token in `SLACK_TOKEN_<teamID>` and the cookie in
    /// `SLACK_COOKIE_<teamID>`. The index is not consulted: choosing the
    /// workspace is the caller's job.
    ///
    /// - Throws: `SlackCredentialError` naming the first item that is
    ///   missing or cannot be read, token first.
    public func credential(for teamID: String) async throws -> SlackCredential {
        let token = try await value(of: SlackKeychain.tokenService(teamID: teamID))
        let cookie = try await value(of: SlackKeychain.cookieService(teamID: teamID))
        return SlackCredential(teamID: teamID, token: token, cookie: cookie)
    }

    /// Writes the token to `SLACK_TOKEN_<teamID>`, then the cookie to
    /// `SLACK_COOKIE_<teamID>`. Both are checked before either is written,
    /// so a refused cookie never leaves a new token beside an old cookie.
    ///
    /// - Throws: `SlackKeychainWriteError` naming the item: `refused` when
    ///   either fails its check (nothing is written), or `failed` /
    ///   `timedOut` for the first write that may not have happened (after a
    ///   token write fails, the cookie is not attempted).
    public func save(_ credential: SlackCredential) async throws {
        let items = [
            (SlackKeychain.tokenService(teamID: credential.teamID), credential.token),
            (SlackKeychain.cookieService(teamID: credential.teamID), credential.cookie),
        ]
        for (service, value) in items { try writer.check(service: service, value: value) }
        for (service, value) in items { try await writer.write(service: service, value: value) }
    }

    /// Replaces `SLACK_WORKSPACES` with `workspaces`, in the given order, as
    /// the standard base64 (with padding) of their JSON array. Keys are
    /// sorted so the same list always gives the same value; any name, in any
    /// script, passes the write path's character check once in base64.
    ///
    /// - Throws: `SlackKeychainWriteError` naming `SLACK_WORKSPACES`.
    public func saveWorkspaces(_ workspaces: [SlackWorkspace]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(workspaces)
        try await writer.write(service: SlackKeychain.workspacesService, value: json.base64EncodedString())
    }

    /// The value of one item, or the error naming it.
    private func value(of service: String) async throws -> String {
        switch await reader.read(service: service) {
        case .found(let value): return value
        case .absent: throw SlackCredentialError.absent(service: service)
        case .timedOut(let seconds): throw SlackCredentialError.timedOut(service: service, after: seconds)
        case .unavailable(let reason): throw SlackCredentialError.unavailable(service: service, reason: reason)
        }
    }
}
