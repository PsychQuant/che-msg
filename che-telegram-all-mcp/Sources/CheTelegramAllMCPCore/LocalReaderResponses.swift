import Foundation
import MCP
import TelegramAllLib

/// Responses while another process holds TDLib (PsychQuant/che-msg#58). Each
/// error is `isError: true` with one JSON text item carrying a `type` field.

/// The tools the local reader answers while another process holds TDLib.
internal let localReaderTools: Set<String> = [
    "get_chats", "search_chats", "get_chat_history", "search_messages", "dump_chat_to_markdown",
]

/// Read tools the local reader does not answer; every other tool needs TDLib.
internal let localReaderUnsupportedTools: Set<String> = [
    "get_me", "get_user", "get_contacts", "get_chat", "get_chat_members",
]

/// `{"type":"tdlib_in_use","lock_holder_pid":<int or null>,"message":...}`
internal func tdlibInUseResult(holderPid: Int32?) -> CallTool.Result {
    jsonErrorResult([
        "type": "tdlib_in_use",
        "lock_holder_pid": holderPid.map { NSNumber(value: $0) } ?? NSNull(),
        "message": "TDLib is in use by \(holderDescription(holderPid)), so this tool cannot run now. "
            + "That session closes TDLib after it has been idle for its idle timeout "
            + "(\(IdleTimeout.environmentVariable), \(Int(IdleTimeout.defaultSeconds)) seconds by default); "
            + "try again then, or use the session that holds it.",
    ])
}

/// `{"type":"local_reader_unsupported","tool":<name>,"message":...}`
internal func localReaderUnsupportedResult(tool: String, holderPid: Int32?) -> CallTool.Result {
    jsonErrorResult([
        "type": "local_reader_unsupported",
        "tool": tool,
        "message": "\(tool) needs TDLib, which is in use by \(holderDescription(holderPid)). While another "
            + "process holds TDLib, only \(localReaderTools.sorted().joined(separator: ", ")) are answered "
            + "from its local cache.",
    ])
}

/// `{"type":"local_reader_unavailable","reason":<reason>,"message":...}`
internal func localReaderUnavailableResult(_ error: LocalReaderError, holderPid: Int32?) -> CallTool.Result {
    jsonErrorResult([
        "type": "local_reader_unavailable",
        "reason": error.reason,
        "message": "TDLib is in use by \(holderDescription(holderPid)) and its local cache cannot be read: "
            + error.description,
    ])
}

/// The second content item of a reader result: where the result came from,
/// how many records could not be decoded, and how recent the cache is for
/// each chat the result covers.
internal func localCacheNote(holderPid: Int32?, result: LocalTDLibReader.Result,
                             timeZone: TimeZone = .current) -> String {
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    day.timeZone = timeZone
    var lines = [
        "source: local-cache",
        "TDLib is in use by \(holderDescription(holderPid)), so this result was read from its local cache, not from Telegram.",
        "undecodable records: \(result.undecodableCount)",
    ]
    for chat in result.freshness {
        switch chat.newest {
        case .date(let unix):
            lines.append("chat \(chat.chatId): newest cached message \(day.string(from: Date(timeIntervalSince1970: TimeInterval(unix))))")
        case .noMessages:
            lines.append("chat \(chat.chatId): no cached messages")
        case .undated:
            lines.append("chat \(chat.chatId): cached messages have no readable date")
        }
    }
    lines.append("The cache holds only messages TDLib has loaded, so newer messages can exist on Telegram.")
    return lines.joined(separator: "\n")
}

private func holderDescription(_ pid: Int32?) -> String {
    pid.map { "another process (PID \($0))" } ?? "another process"
}

private func jsonErrorResult(_ payload: [String: Any]) -> CallTool.Result {
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                           isError: true)
}
