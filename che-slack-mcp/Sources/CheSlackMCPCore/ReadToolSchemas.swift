import Foundation
import MCP
import SlackWebLib

/// The `tools/list` entries for the read tools. The ranges and defaults
/// here are the ones `ReadTools.swift` enforces; ToolListTests pins both.
extension SlackToolHandler {
    static let readTools: [Tool] = [
        tool("list_conversations",
             description: """
             List the conversations you are a member of in one workspace: public channels, private channels, \
             direct messages (im) and group direct messages (mpim), archived ones left out. Each has id, type and \
             name; a direct message's name is the other user's display name (else real name), with user_id, or \
             name_error when it could not be looked up. At most \(SlackWebClient.conversationsMaxPages) pages of \
             \(SlackWebClient.conversationsPageSize) are read and at most \(directMessageNameLookupLimit) users \
             looked up per call; has_more is true when conversations were left out.
             """,
             properties: workspaceProperty),
        tool("get_conversation_history",
             description: """
             Read a conversation's top-level messages, newest first: ts, user_id (or bot_id), sender_name when \
             Slack sends one with the message, text, and reply_count and thread_ts for a thread parent (pass that \
             ts to get_thread_replies). Names are not looked up; use get_user. has_more is true when older messages \
             exist.
             """,
             properties: workspaceProperty.merging([
                 "conversation_id": prop("string", "The conversation's id, such as C0123ABCD, from list_conversations."),
                 "limit": integerProp(historyLimit, "How many messages to return."),
                 "oldest": prop("string", """
                     Only messages after this Slack timestamp, written as a string such as "1730000000.000100".
                     """),
                 "latest": prop("string", """
                     Only messages before this Slack timestamp, written as a string such as "1730000000.000100".
                     """),
             ]) { $1 },
             required: ["conversation_id"]),
        tool("get_thread_replies",
             description: """
             Read a thread: the parent message followed by its replies, oldest first, with the same fields as \
             get_conversation_history. At most \(SlackWebClient.repliesMaxPages) pages of \
             \(SlackWebClient.repliesPageSize) are read; has_more is true when replies were left out.
             """,
             properties: workspaceProperty.merging([
                 "conversation_id": prop("string", "The conversation's id, such as C0123ABCD."),
                 "thread_ts": prop("string", """
                     The parent message's ts, written as a string such as "1730000000.000100".
                     """),
             ]) { $1 },
             required: ["conversation_id", "thread_ts"]),
        tool("get_user",
             description: """
             Look up a user by id: display_name (as Slack has it, possibly empty), real_name and is_bot.
             """,
             properties: workspaceProperty.merging([
                 "user_id": prop("string", "The user's id, such as U0123ABCD."),
             ]) { $1 },
             required: ["user_id"]),
        tool("search_messages",
             description: """
             Search messages with Slack's search. The query is passed unchanged, so modifiers such as in:#general, \
             from:@name, before:2026-01-01 and quoted phrases work. Each match has conversation_id, \
             conversation_name (for a direct message, the other user's id), ts, user_id, sender_name (the handle \
             Slack sends), text and permalink; total is Slack's count of all matches.
             """,
             properties: workspaceProperty.merging([
                 "query": prop("string", "The search query; must not be empty or only spaces."),
                 "count": integerProp(searchCount, "How many matches to return."),
             ]) { $1 },
             required: ["query"]),
    ]

    static func integerProp(_ bounds: IntegerBounds, _ description: String) -> Value {
        .object([
            "type": .string("integer"),
            "minimum": .int(bounds.range.lowerBound),
            "maximum": .int(bounds.range.upperBound),
            "default": .int(bounds.defaultValue),
            "description": .string("\(description) From \(bounds.range.lowerBound) to \(bounds.range.upperBound); "
                                   + "default \(bounds.defaultValue)."),
        ])
    }
}
