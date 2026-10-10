import Foundation
import MCP
import TelegramAllLib

// MARK: - Sync note (PsychQuant/che-msg#63)

/// The second text item of a TDLib-path answer while TDLib is not synced with
/// Telegram, or nil when it is. Same convention as `localCacheNote`: a
/// machine-readable first line, then prose for the reader.
///
/// A session Telegram has invalidated keeps TDLib `ready` and never syncs, so
/// past the stall threshold the note names that likely cause and the remedy.
internal func syncNote(_ state: TDLibSyncState.Snapshot,
                       stallThreshold: Int = TDLibSyncState.stallThreshold) -> String? {
    guard !state.isSynced else { return nil }
    let connection = state.connectionState ?? "no connection state reported yet"
    var lines = [
        "sync: not-synced",
        "TDLib has not finished syncing with Telegram (\(connection); not synced for \(state.unsyncedSeconds) s).",
        "Messages and changes newer than what TDLib last received can be absent from this result.",
    ]
    if state.unsyncedSeconds >= stallThreshold {
        lines.append("Not synced for \(state.unsyncedSeconds) s: a session invalidated by Telegram "
                     + "(for example, the same session used in two places at once) is the likely cause. "
                     + "To recover, call logout, then log in again with auth_run.")
    }
    return lines.joined(separator: "\n")
}

/// Appends the sync note to a successful answer while authorization is ready
/// and TDLib is not synced; returns every other result unchanged.
internal func withSyncNote(_ result: CallTool.Result, authReady: Bool,
                           snapshot: TDLibSyncState.Snapshot) -> CallTool.Result {
    guard result.isError != true, authReady, let note = syncNote(snapshot) else { return result }
    return CallTool.Result(content: result.content + [.text(text: note, annotations: nil, _meta: nil)],
                           isError: result.isError)
}
