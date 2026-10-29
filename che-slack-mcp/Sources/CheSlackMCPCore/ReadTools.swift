import Foundation
import MCP
import SlackWebLib

/// The read tools (spec: slack-mcp-tools, "Conversation read tools" and
/// "Message search"). Each checks its arguments first, so a refused
/// argument reads no Keychain item and calls no Slack method, then runs
/// inside `withWorkspace` for selection and error results.
extension SlackToolHandler {
    /// Runs `body` with the checked arguments inside `withWorkspace`, or
    /// returns the argument refusal.
    func checked<Request>(_ arguments: [String: Value],
                          _ parse: (ToolArguments) throws(ToolFailure) -> Request,
                          _ body: (Request, ResolvedWorkspace) async throws -> CallTool.Result) async -> CallTool.Result {
        let request: Request
        do {
            request = try parse(ToolArguments(arguments))
        } catch {
            return error.result
        }
        return await withWorkspace(arguments) { try await body(request, $0) }
    }

    // MARK: - Messages

    /// One message as the read tools return it. The sender is `user_id`
    /// (or `bot_id` for a bot) plus `sender_name`, a name Slack sent along
    /// with the message; no extra request is made to look a name up (call
    /// `get_user` for that). Absent fields are left out, except `text`,
    /// which is `""` when Slack sends none.
    struct ListedMessage: Encodable {
        let ts: String
        let user_id: String?
        let bot_id: String?
        let sender_name: String?
        let text: String
        let thread_ts: String?
        let reply_count: Int?
        let subtype: String?

        init(_ message: SlackMessage) {
            ts = message.ts
            user_id = message.user
            bot_id = message.botID
            sender_name = message.senderName
            text = message.text ?? ""
            thread_ts = message.threadTS
            reply_count = message.replyCount
            subtype = message.subtype
        }
    }

    static let conversationIDMeaning = "the id of a conversation, such as C0123ABCD (see list_conversations)"

    /// `get_conversation_history`'s `limit`: the 200 maximum is Slack's
    /// recommended page size; the default of 50 is our own choice (design:
    /// 參數上限與來源).
    static let historyLimit = IntegerBounds(range: 1...200, defaultValue: 50)
    /// `search_messages`'s `count`: Slack's own default and maximum.
    static let searchCount = IntegerBounds(range: 1...100, defaultValue: 20)

    // MARK: - list_conversations

    /// Distinct users looked up with `users.info` at most per
    /// `list_conversations` call, so a long list of direct messages costs a
    /// bounded number of requests (about 18 s at the default 350 ms pacing).
    static let directMessageNameLookupLimit = 50

    /// `name` is the channel's name, or for a direct message the other
    /// user's display name (else real name, else handle). A direct message
    /// whose name was not found has `name_error` instead: Slack's error code,
    /// `lookup_limit` past `directMessageNameLookupLimit`, `no_name`, or
    /// `no_user` when Slack sent no user id for it.
    private struct ListedConversation: Encodable {
        let id: String
        let type: String
        let name: String?
        let user_id: String?
        let name_error: String?
    }

    private struct ConversationList: Encodable {
        let conversations: [ListedConversation]
        let has_more: Bool
    }

    func listConversations(_ arguments: [String: Value]) async -> CallTool.Result {
        await withWorkspace(arguments) { selection in
            let listing = try await client.userConversations(credential: selection.credential)
            var names = DirectMessageNames(limit: Self.directMessageNameLookupLimit)
            var listed: [ListedConversation] = []
            for conversation in listing.conversations {
                guard conversation.kind == .im, let user = conversation.user else {
                    let missingUser = conversation.kind == .im ? "no_user" : nil
                    listed.append(ListedConversation(id: conversation.id, type: conversation.kind.rawValue,
                                                     name: conversation.name, user_id: nil, name_error: missingUser))
                    continue
                }
                let name = try await names.name(of: user) {
                    try await client.userInfo(user: user, credential: selection.credential)
                }
                listed.append(ListedConversation(id: conversation.id, type: conversation.kind.rawValue,
                                                 name: name.value, user_id: user, name_error: name.error))
            }
            return ToolResult.json(ConversationList(conversations: listed, has_more: listing.hasMore))
        }
    }

    // MARK: - get_conversation_history

    private struct HistoryRequest {
        let channel: String
        let limit: Int
        let oldest: String?
        let latest: String?
    }

    private struct History: Encodable {
        let conversation_id: String
        let messages: [ListedMessage]
        let has_more: Bool
    }

    func conversationHistory(_ arguments: [String: Value]) async -> CallTool.Result {
        await checked(arguments, { args throws(ToolFailure) in
            HistoryRequest(channel: try args.id("conversation_id", Self.conversationIDMeaning),
                           limit: try args.integer("limit", Self.historyLimit),
                           oldest: try args.optionalTimestamp("oldest"),
                           latest: try args.optionalTimestamp("latest"))
        }) { request, selection in
            let page = try await client.conversationHistory(channel: request.channel, limit: request.limit,
                                                            oldest: request.oldest, latest: request.latest,
                                                            credential: selection.credential)
            return ToolResult.json(History(conversation_id: request.channel,
                                           messages: page.messages.map(ListedMessage.init), has_more: page.hasMore))
        }
    }

    // MARK: - get_thread_replies

    private struct Thread: Encodable {
        let conversation_id: String
        let thread_ts: String
        let messages: [ListedMessage]
        let has_more: Bool
    }

    func threadReplies(_ arguments: [String: Value]) async -> CallTool.Result {
        await checked(arguments, { args throws(ToolFailure) in
            (channel: try args.id("conversation_id", Self.conversationIDMeaning), ts: try args.timestamp("thread_ts"))
        }) { request, selection in
            let page = try await client.conversationReplies(channel: request.channel, ts: request.ts,
                                                            credential: selection.credential)
            return ToolResult.json(Thread(conversation_id: request.channel, thread_ts: request.ts,
                                          messages: page.messages.map(ListedMessage.init), has_more: page.hasMore))
        }
    }

    // MARK: - get_user

    /// `display_name` is Slack's own, so it may be `""`; `real_name` comes
    /// from the user or else its profile. No other profile field is
    /// returned.
    private struct UserSummary: Encodable {
        let user_id: String
        let display_name: String?
        let real_name: String?
        let is_bot: Bool?
    }

    func user(_ arguments: [String: Value]) async -> CallTool.Result {
        await checked(arguments, { args throws(ToolFailure) in
            try args.id("user_id", "the id of a user, such as U0123ABCD")
        }) { userID, selection in
            let user = try await client.userInfo(user: userID, credential: selection.credential)
            return ToolResult.json(UserSummary(user_id: user.id, display_name: user.displayName,
                                               real_name: user.fullName, is_bot: user.isBot))
        }
    }

    // MARK: - search_messages

    /// One search match. `sender_name` is the `username` Slack sends with
    /// the match (usually the handle); for a direct message,
    /// `conversation_name` is the other user's id, as Slack sends it.
    private struct ListedMatch: Encodable {
        let conversation_id: String?
        let conversation_name: String?
        let ts: String
        let user_id: String?
        let sender_name: String?
        let text: String
        let permalink: String?

        init(_ match: SlackSearchMatch) {
            conversation_id = match.channel?.id
            conversation_name = match.channel?.name
            ts = match.ts
            user_id = match.user
            sender_name = match.username.flatMap { $0.isEmpty ? nil : $0 }
            text = match.text ?? ""
            permalink = match.permalink
        }
    }

    private struct SearchResult: Encodable {
        let matches: [ListedMatch]
        let total: Int?
    }

    func searchMessages(_ arguments: [String: Value]) async -> CallTool.Result {
        await checked(arguments, { args throws(ToolFailure) in
            (query: try args.nonBlankString("query", "the Slack search query, passed to Slack unchanged"),
             count: try args.integer("count", Self.searchCount))
        }) { request, selection in
            let found = try await client.searchMessages(query: request.query, count: request.count,
                                                        credential: selection.credential)
            return ToolResult.json(SearchResult(matches: found.matches.map(ListedMatch.init), total: found.total))
        }
    }
}
