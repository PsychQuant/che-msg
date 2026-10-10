import Foundation

/// A TDLib client that can be asked to log out (PsychQuant/che-msg#63).
public protocol TDLibLoggingOut: AnyObject {
    /// Asks TDLib to log out; true when it finished within `timeout` seconds.
    func logOut(timeout: TimeInterval) async -> Bool
    /// Closes TDLib; true when it reported closing within `timeout` seconds.
    func close(timeout: TimeInterval) async -> Bool
}

/// `logout` for a session that may no longer sync (#63).
///
/// TDLib normally clears its database itself when it logs out. A session
/// Telegram has invalidated may never finish: then TDLib is closed and its
/// database directory is renamed aside, so the next login starts from a new,
/// empty directory. Nothing is ever deleted — the directory holds the only
/// local copy of the account's messages.
public enum TDLibSessionReset {
    public enum ResetError: Error, Equatable {
        /// TDLib neither finished the logout nor closed; nothing was changed.
        case couldNotClose
        /// TDLib is closed but the directory could not be renamed; it is unchanged.
        case renameFailed(String)
    }

    public static let timeout: TimeInterval = 30

    /// `tdlib.invalidated-<UTC yyyyMMdd-HHmmss>`.
    public static func renamedName(at date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return "tdlib.invalidated-" + format.string(from: date)
    }

    /// Logs `client` out. Returns the directory `directory` was renamed to, or
    /// nil when TDLib finished the logout itself.
    public static func reset(client: TDLibLoggingOut, directory: URL,
                             timeout: TimeInterval = TDLibSessionReset.timeout, now: Date) async throws -> URL? {
        if await client.logOut(timeout: timeout) { return nil }
        guard await client.close(timeout: timeout) else { throw ResetError.couldNotClose }
        let target = directory.deletingLastPathComponent().appendingPathComponent(renamedName(at: now))
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ResetError.renameFailed("\(target.path) already exists")
        }
        do {
            try FileManager.default.moveItem(at: directory, to: target)
        } catch {
            throw ResetError.renameFailed(error.localizedDescription)
        }
        return target
    }
}
