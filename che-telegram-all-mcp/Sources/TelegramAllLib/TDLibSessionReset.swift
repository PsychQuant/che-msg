import Foundation

/// `logout` as a local reset (PsychQuant/che-msg#63).
///
/// No log-out request goes to Telegram: TDLib's `logOut` waits for the server
/// with no timeout (forever when offline), and when it completes TDLib clears
/// its local database — the only local copy of the account's messages. So the
/// reset closes TDLib and renames its database directory aside; the next login
/// starts from a new, empty directory. Nothing is ever deleted. The old
/// session stays in the account's device list until it is ended in a Telegram
/// app, and the renamed directory still holds a working auth key: it must not
/// be moved back while a new session is in use.
public enum TDLibSessionReset {
    public enum ResetError: Error, Equatable {
        /// TDLib did not close; nothing was changed.
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

    /// Closes `client` and renames `directory` aside; returns the new location.
    public static func reset(client: TDLibClosable, directory: URL,
                             timeout: TimeInterval = TDLibSessionReset.timeout, now: Date) async throws -> URL {
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
