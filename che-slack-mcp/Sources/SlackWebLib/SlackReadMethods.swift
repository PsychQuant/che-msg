import Foundation

/// Typed wrappers for the Slack methods the read tools use. Each sends its
/// parameters as given, and throws the call's `SlackError`, or
/// `slackError("unexpected_response")` when an `ok: true` answer lacks a
/// field it needs or holds one of the wrong JSON type (the decoding error
/// could quote the body; a fixed code cannot).
extension SlackWebClient {
    /// Decodes an `ok: true` answer.
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let answer = try? JSONDecoder().decode(T.self, from: data) else {
            throw SlackError.slackError("unexpected_response")
        }
        return answer
    }

    private struct MessagesAnswer: Decodable {
        let messages: [SlackMessage]
        let hasMore: Bool?
        let responseMetadata: SlackResponseMetadata?

        enum CodingKeys: String, CodingKey {
            case messages
            case hasMore = "has_more"
            case responseMetadata = "response_metadata"
        }

        /// Slack's `has_more`, or a next cursor when `has_more` is absent.
        var more: Bool { hasMore ?? (SlackResponseMetadata.cursor(responseMetadata) != nil) }
    }

    /// One `conversations.history` request: up to `limit` top-level
    /// messages of `channel`, newest first as Slack returns them. `oldest`,
    /// `latest` and `cursor` (a previous page's `nextCursor`) are sent only
    /// when given.
    public func conversationHistory(channel: String, limit: Int, oldest: String? = nil, latest: String? = nil,
                                    cursor: String? = nil,
                                    credential: SlackCredential) async throws -> SlackMessagePage {
        var parameters = ["channel": channel, "limit": String(limit)]
        parameters["oldest"] = oldest
        parameters["latest"] = latest
        parameters["cursor"] = cursor
        let answer = try Self.decode(MessagesAnswer.self,
                                     try await call("conversations.history", parameters: parameters, credential: credential))
        return SlackMessagePage(messages: answer.messages, hasMore: answer.more,
                                nextCursor: SlackResponseMetadata.cursor(answer.responseMetadata))
    }

    /// Every kind of conversation, as `users.conversations` names them.
    public static let allConversationTypes = "public_channel,private_channel,mpim,im"
    /// Conversations requested per `users.conversations` page.
    public static let conversationsPageSize = 200
    /// Pages fetched at most for one listing (2000 conversations at
    /// `conversationsPageSize`).
    public static let conversationsMaxPages = 10

    private struct ConversationsAnswer: Decodable {
        let channels: [SlackConversation]
        let responseMetadata: SlackResponseMetadata?

        enum CodingKeys: String, CodingKey {
            case channels
            case responseMetadata = "response_metadata"
        }
    }

    /// The conversations the user is a member of, from `users.conversations`
    /// (unlike `conversations.list`, which with a user token also lists
    /// public channels the user has not joined), every kind, archived ones
    /// left out, following `next_cursor` for at most `maxPages` pages. A
    /// failure on any page fails the whole call.
    public func userConversations(pageSize: Int = conversationsPageSize, maxPages: Int = conversationsMaxPages,
                                  credential: SlackCredential) async throws -> SlackConversationList {
        var conversations: [SlackConversation] = []
        var cursor: String?
        for _ in 0..<max(1, maxPages) {
            var parameters = ["types": Self.allConversationTypes, "exclude_archived": "true", "limit": String(pageSize)]
            parameters["cursor"] = cursor
            let answer = try Self.decode(ConversationsAnswer.self,
                                         try await call("users.conversations", parameters: parameters, credential: credential))
            conversations += answer.channels
            cursor = SlackResponseMetadata.cursor(answer.responseMetadata)
            if cursor == nil { break }
        }
        return SlackConversationList(conversations: conversations, hasMore: cursor != nil)
    }

    private struct UserAnswer: Decodable {
        let user: SlackUser
    }

    /// `users.info` for `user`.
    public func userInfo(user: String, credential: SlackCredential) async throws -> SlackUser {
        try Self.decode(UserAnswer.self,
                        try await call("users.info", parameters: ["user": user], credential: credential)).user
    }

    private struct SearchAnswer: Decodable {
        struct Messages: Decodable {
            let matches: [SlackSearchMatch]
            let total: Int?
        }

        let messages: Messages
    }

    /// One `search.messages` request with `query` exactly as given, so
    /// Slack's modifiers (`in:#general`, `from:@name`) keep working, and
    /// `count` matches. No sort or page is sent: Slack's defaults apply.
    public func searchMessages(query: String, count: Int, credential: SlackCredential) async throws -> SlackSearchResult {
        let answer = try Self.decode(SearchAnswer.self,
                                     try await call("search.messages", parameters: ["query": query, "count": String(count)],
                                                    credential: credential))
        return SlackSearchResult(matches: answer.messages.matches, total: answer.messages.total)
    }

    /// Messages requested per `conversations.replies` page.
    public static let repliesPageSize = 200
    /// Pages fetched at most for one thread, so a huge thread costs at most
    /// this many requests (1000 messages at `repliesPageSize`).
    public static let repliesMaxPages = 5

    /// A thread: `conversations.replies` for the parent `ts`, following
    /// `next_cursor` for at most `maxPages` pages. Messages keep Slack's
    /// order (parent first, then replies oldest first); a message already
    /// seen on an earlier page (Slack may repeat the parent) is kept once.
    /// `oldest`, sent only when given, asks for the replies after it
    /// (exclusive, Slack's default), so a thread longer than `maxPages`
    /// continues after the newest reply already read; the parent may still
    /// come first. `hasMore` is true when the page limit stopped the walk
    /// while Slack still offered a cursor. A failure on any page fails the
    /// whole call.
    public func conversationReplies(channel: String, ts: String, oldest: String? = nil,
                                    pageSize: Int = repliesPageSize, maxPages: Int = repliesMaxPages,
                                    credential: SlackCredential) async throws -> SlackMessagePage {
        var messages: [SlackMessage] = []
        var seen: Set<String> = []
        var cursor: String?
        for _ in 0..<max(1, maxPages) {
            var parameters = ["channel": channel, "ts": ts, "limit": String(pageSize)]
            parameters["oldest"] = oldest
            parameters["cursor"] = cursor
            let answer = try Self.decode(MessagesAnswer.self,
                                         try await call("conversations.replies", parameters: parameters,
                                                        credential: credential))
            for message in answer.messages where seen.insert(message.ts).inserted {
                messages.append(message)
            }
            cursor = SlackResponseMetadata.cursor(answer.responseMetadata)
            if cursor == nil { break }
        }
        return SlackMessagePage(messages: messages, hasMore: cursor != nil)
    }
}
