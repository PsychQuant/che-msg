import Foundation

/// Why a Keychain item was not deleted, or may not have been. Every case
/// names the item's service; every reason is a fixed phrase, never text the
/// child printed.
public enum SlackKeychainDeleteError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Refused before any process started: nothing was deleted.
    case refused(service: String, reason: SlackKeychainWriteRefusal)
    /// `security delete-generic-password` could not run or failed. The item
    /// may or may not still exist.
    case failed(service: String, reason: String)
    /// `security` was still running after `after` seconds and was stopped.
    case timedOut(service: String, after: TimeInterval)

    public var service: String {
        switch self {
        case .refused(let service, _), .failed(let service, _), .timedOut(let service, _): return service
        }
    }

    public var description: String {
        let item = "Keychain item \(service)"
        switch self {
        case .refused(_, let reason):
            return "Refused to delete \(item): \(reason.rawValue); nothing was deleted."
        case .failed(_, let reason):
            return "Deleting \(item) may have failed: \(reason)."
        case .timedOut(_, let seconds):
            return "Deleting \(item) did not finish within \(formatSeconds(seconds)) s; it may or may not have been deleted."
        }
    }

    public var errorDescription: String? { description }
}

extension SecurityCLIKeychainWriter {
    /// Deletes the item with `/usr/bin/security delete-generic-password -a
    /// che-slack-mcp -s <service>` (plus the keychain path when one is
    /// given). No value is involved, so the arguments carry nothing secret;
    /// stdin, stdout and stderr are the null device, so nothing the tool
    /// prints (it lists the deleted item's attributes) is kept.
    ///
    /// Exit 0 (deleted) and 44 (no such item) both count as gone, but only
    /// once reading the item back finds nothing: `delete-generic-password`
    /// removes the first match in the search list, so a second keychain
    /// holding the same item would otherwise leave a readable credential
    /// behind a reported success.
    public func delete(service: String) async throws {
        if let reason = KeychainWritePolicy.serviceRefusal(service) {
            throw SlackKeychainDeleteError.refused(service: service, reason: reason)
        }
        let process = Process()
        process.executableURL = executable
        var arguments = ["delete-generic-password", "-a", SlackKeychain.account, "-s", service]
        if let keychainPath { arguments.append(keychainPath) }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        switch await runBounded(process, timeout: timeout, killGrace: Self.killGrace) {
        case .timedOut:
            throw SlackKeychainDeleteError.timedOut(service: service, after: timeout)
        case .couldNotStart:
            throw SlackKeychainDeleteError.failed(service: service, reason: "could not start \(executable.path)")
        case .exited(0), .exited(44):
            break
        case .exited(let status):
            throw SlackKeychainDeleteError.failed(service: service, reason: "security exited with status \(status)")
        }
        try await confirmGone(service: service)
    }

    /// Reads the item back the way `SecurityCLIKeychainReader` does and
    /// throws `failed` unless it is absent.
    private func confirmGone(service: String) async throws {
        let reader = SecurityCLIKeychainReader(executable: executable, keychainPath: keychainPath, timeout: timeout)
        let reason: String
        switch await reader.read(service: service) {
        case .absent:
            return
        case .found:
            reason = "the item still exists when read back"
        case .timedOut(let seconds):
            reason = "reading the item back did not finish within \(formatSeconds(seconds)) s"
        case .unavailable(let why):
            reason = "reading the item back failed: \(why)"
        }
        throw SlackKeychainDeleteError.failed(service: service, reason: reason)
    }
}
