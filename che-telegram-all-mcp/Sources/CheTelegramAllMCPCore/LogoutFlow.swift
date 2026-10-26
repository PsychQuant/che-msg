import Foundation
import MCP
import TelegramAllLib

/// The `logout` tool (PsychQuant/che-msg#63): a local reset that sends no
/// log-out request to Telegram. On success TDLib is released (`discard`) and the sync
/// state starts again (`resetSync`). On failure neither happens: when TDLib
/// did not close in time the directory was not moved and TDLib is still held
/// (the close request was sent, so TDLib can still close later; #64), and when
/// the directory could not be renamed TDLib stays held so that no client
/// reopens the old directory.
internal func performLocalReset(client: TDLibClosable, directory: URL, now: Date,
                                discard: () async -> Void, resetSync: () -> Void) async -> CallTool.Result {
    func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)], isError: true)
    }
    let renamed: URL
    do {
        renamed = try await TDLibSessionReset.reset(client: client, directory: directory, now: now)
    } catch TDLibSessionReset.ResetError.couldNotClose {
        return failure("TDLib did not close within \(Int(TDLibSessionReset.timeout)) s; "
                     + "the directory was not moved and TDLib is still held; try again.")
    } catch TDLibSessionReset.ResetError.renameFailed(let reason) {
        return failure("TDLib is closed, but its database directory could not be renamed (\(reason)); it is unchanged. "
                     + "Move \(directory.path) aside by hand, then reconnect telegram-all with /mcp.")
    } catch {
        return failure("\(error)")
    }
    await discard()
    resetSync()
    let payload: [String: Any] = [
        "ok": true,
        "renamed_directory": renamed.path,
        "note": "The local session was reset without sending a log-out request to Telegram; its database was moved aside, "
            + "not deleted. Now end the old session, which stays valid in the account's device list, in a Telegram app "
            + "(Settings > Devices), then log in again with auth_run. The moved directory still holds a working auth key: "
            + "do not move it back while a new session is in use.",
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"ok":true}"#.utf8)
    return CallTool.Result(content: [.text(text: String(data: data, encoding: .utf8) ?? #"{"ok":true}"#,
                                           annotations: nil, _meta: nil)], isError: false)
}

/// Lets one `logout` run at a time in a server (#64, finding 3). A second
/// `logout` that arrives while one is running fails at once rather than
/// waiting: run later, it would reset the client the first one had already
/// discarded and could rename the directory of a client opened since.
internal final class LogoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    /// Runs `body` unless a logout is running, in which case it answers that
    /// without calling `body`.
    func run(_ body: () async -> CallTool.Result) async -> CallTool.Result {
        guard enter() else {
            return CallTool.Result(content: [.text(text: "Error: another logout is already running in this server; "
                                                   + "this call did nothing. Wait for that logout's result before "
                                                   + "calling logout again.", annotations: nil, _meta: nil)],
                                   isError: true)
        }
        defer { leave() }
        return await body()
    }

    /// Marks a logout as running; false when one already is.
    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    func leave() {
        lock.lock()
        running = false
        lock.unlock()
    }
}
