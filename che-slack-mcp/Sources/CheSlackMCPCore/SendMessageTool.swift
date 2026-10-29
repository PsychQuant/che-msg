import Foundation
import MCP
import SlackWebLib

/// `send_message` (spec: slack-mcp-tools, "Send message"). Arguments are
/// checked first, so a refused argument reads no Keychain item and posts
/// nothing.
extension SlackToolHandler {
    /// `text`'s maximum, in UTF-16 code units. Slack's documentation says
    /// "Slack will truncate messages containing more than 40,000
    /// characters"; a longer text is refused here instead of being cut short
    /// (design: 參數上限與來源). Which unit Slack counts is not established
    /// here, so the count used is the largest of UTF-16 units, Unicode
    /// scalars and Characters: a text accepted here is not over 40000 in any
    /// of them. UTF-8 bytes are not considered: Slack says characters.
    static let maxTextLength = 40000

    static let writeTools: [Tool] = [
        tool("send_message",
             description: """
             Post a message as you (the signed-in user) to a conversation, at once; its members see it. With \
             thread_ts, the message is a reply in that thread. text is sent exactly as given, so Slack formatting \
             such as *bold* and <@U0123ABCD> mentions applies. Returns the conversation id and the new message's ts.
             """,
             properties: workspaceProperty.merging([
                 "conversation_id": prop("string", "The conversation's id, such as C0123ABCD, from list_conversations."),
                 "text": prop("string", """
                     The message to post: not empty or only spaces, and at most \(maxTextLength) characters counted as \
                     UTF-16 code units (an emoji may count as 2). Split a longer text into several messages.
                     """),
                 "thread_ts": prop("string", """
                     To reply in a thread: the parent message's ts, written as a string such as "1730000000.000100".
                     """),
             ]) { $1 },
             required: ["conversation_id", "text"]),
    ]

    private struct SendRequest {
        let channel: String
        let text: String
        let threadTS: String?
    }

    private struct Sent: Encodable {
        let conversation_id: String
        let ts: String
    }

    func sendMessage(_ arguments: [String: Value]) async -> CallTool.Result {
        await checked(arguments, { args throws(ToolFailure) in
            SendRequest(channel: try args.id("conversation_id", Self.conversationIDMeaning),
                        text: try args.nonBlankString("text", "the message to post",
                                                      maxUTF16Length: Self.maxTextLength),
                        threadTS: try args.optionalTimestamp("thread_ts"))
        }) { request, selection in
            let posted: SlackPostedMessage
            do {
                posted = try await client.postMessage(channel: request.channel, text: request.text,
                                                      threadTS: request.threadTS, credential: selection.credential)
            } catch let error as SlackError where Self.mayHavePosted(error) {
                var message = ToolText.describe(error, in: selection.workspace)
                if !message.hasSuffix(".") { message += "." }
                throw ToolFailure("\(message) \(Self.mayHavePostedNote)")
            }
            return ToolResult.json(Sent(conversation_id: posted.channel, ts: posted.ts))
        }
    }

    static let mayHavePostedNote =
        "The message may have been posted; read the conversation with get_conversation_history before sending it again."

    /// Whether Slack may have posted the message although the call failed,
    /// so the error must not read as "nothing was sent". A closed list, only
    /// these three; no other error is to be added by analogy:
    /// 1. `network`: the transport failed, possibly after Slack received the
    ///    request.
    /// 2. `slackError` `invalid_json` or `http_<status>`: an answer came back
    ///    that does not say whether Slack posted (an HTML error page, a 502).
    /// 3. `slackError` `unexpected_response`: Slack answered `ok: true`, so
    ///    it posted, but without the new message's `channel` and `ts`.
    /// Every other error is Slack saying it did not post: an `ok: false`
    /// code (`channel_not_found`, `not_in_channel`, `is_archived`, ...),
    /// `sessionInvalid`, `enterpriseRestricted`, or `rateLimited`, since
    /// Slack does not process a request it rate limits.
    static func mayHavePosted(_ error: SlackError) -> Bool {
        switch error {
        case .network:
            return true
        case let .slackError(code):
            return code == "invalid_json" || code == "unexpected_response" || code.hasPrefix("http_")
        case .sessionInvalid, .enterpriseRestricted, .rateLimited:
            return false
        }
    }
}
