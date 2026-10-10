import Foundation
import MCP
import TelegramAllLib

// MARK: - Sync note (PsychQuant/che-msg#63)

/// The read tools: only their answers can be stale, so only they carry the
/// sync note. Authentication tools, `logout` and tools that change data never
/// do (their JSON stays a single item; "messages can be absent" means nothing
/// for a write).
internal let syncNoteTools: Set<String> = [
    "get_chats", "search_chats", "get_chat_history", "search_messages", "dump_chat_to_markdown",
    "get_me", "get_user", "get_contacts", "get_chat", "get_chat_members",
]

internal func shouldAttachSyncNote(tool: String) -> Bool { syncNoteTools.contains(tool) }

/// The second text item of a read-tool answer while TDLib is not synced with
/// Telegram, or nil when it is. Same convention as `localCacheNote`: a
/// machine-readable first line, then prose for the reader.
///
/// Without a network the note says so. A session Telegram has invalidated
/// keeps TDLib `ready` and updating forever, so past the stall threshold the
/// note names that likely cause and the remedy — after asking the user, as
/// `logout` resets the local session and a new login needs a code.
internal func syncNote(_ state: TDLibSyncState.Snapshot) -> String? {
    guard !state.isSynced else { return nil }
    let connection = state.connectionState ?? "no connection state reported yet"
    var lines = [
        "sync: not-synced",
        "TDLib has not finished syncing with Telegram (\(connection); not synced for \(state.unsyncedSeconds) s).",
        "Messages and changes newer than what TDLib last received can be absent from this result.",
    ]
    if state.connectionState == "connectionStateWaitingForNetwork"
        || state.connectionState == "connectionStateConnectingToProxy" {
        lines.append("TDLib reports no connection to Telegram: check the network or proxy.")
    }
    if state.isStalled() {
        lines.append("Updating for \(state.updatingSeconds) s without finishing: a session invalidated by Telegram "
                     + "(for example, the same session used in two places at once) is the likely cause. "
                     + "To recover, ask the user first; then call logout (it resets the local session) and log in again with auth_run.")
    }
    return lines.joined(separator: "\n")
}

/// Appends the sync note to a successful read-tool answer while authorization
/// is ready and TDLib is not synced; returns every other result unchanged.
internal func withSyncNote(_ result: CallTool.Result, tool: String, authReady: Bool,
                           snapshot: TDLibSyncState.Snapshot) -> CallTool.Result {
    guard result.isError != true, authReady, shouldAttachSyncNote(tool: tool),
          let note = syncNote(snapshot) else { return result }
    return CallTool.Result(content: result.content + [.text(text: note, annotations: nil, _meta: nil)],
                           isError: result.isError)
}
