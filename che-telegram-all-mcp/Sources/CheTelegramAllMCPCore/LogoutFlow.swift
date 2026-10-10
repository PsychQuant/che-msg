import Foundation
import MCP
import TelegramAllLib

/// The `logout` tool (PsychQuant/che-msg#63): a local reset that never
/// contacts Telegram. On success TDLib is released (`discard`) and the sync
/// state starts again (`resetSync`). On failure neither happens: when TDLib
/// would not close nothing changed, and when the directory could not be
/// renamed TDLib stays held so that no client reopens the old directory.
internal func performLocalReset(client: TDLibClosable, directory: URL, now: Date,
                                discard: () async -> Void, resetSync: () -> Void) async -> CallTool.Result {
    func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)], isError: true)
    }
    let renamed: URL
    do {
        renamed = try await TDLibSessionReset.reset(client: client, directory: directory, now: now)
    } catch TDLibSessionReset.ResetError.couldNotClose {
        return failure("TDLib did not close within \(Int(TDLibSessionReset.timeout)) s; nothing was changed. Try again.")
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
        "note": "The local session was reset without contacting Telegram; its database was moved aside, not deleted. "
            + "Log in again with auth_run. The old session stays in the account's device list until you end it in a "
            + "Telegram app (Settings > Devices). The moved directory still holds a working auth key: do not move it "
            + "back while a new session is in use.",
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data(#"{"ok":true}"#.utf8)
    return CallTool.Result(content: [.text(text: String(data: data, encoding: .utf8) ?? #"{"ok":true}"#,
                                           annotations: nil, _meta: nil)], isError: false)
}
