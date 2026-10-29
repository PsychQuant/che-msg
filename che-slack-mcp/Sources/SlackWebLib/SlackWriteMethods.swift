import Foundation

/// The message `chat.postMessage` created: the conversation it went to (for
/// a user id passed as the channel, Slack answers with the direct message's
/// id) and its `ts`.
public struct SlackPostedMessage: Equatable, Sendable, Decodable {
    public let channel: String
    public let ts: String

    public init(channel: String, ts: String) {
        self.channel = channel
        self.ts = ts
    }
}

/// Typed wrappers for the Slack methods that change something. Same rules
/// as the read wrappers: parameters are sent as given, and an `ok: true`
/// answer without a field it needs is `slackError("unexpected_response")`.
extension SlackWebClient {
    /// One `chat.postMessage` request with `channel`, `text` and, only when
    /// given, `thread_ts`, posting as the signed-in user. No other option is
    /// sent, so Slack's defaults apply. Only `rateLimited` answers are
    /// retried (by `call`); Slack does not post a message it rate limited.
    public func postMessage(channel: String, text: String, threadTS: String? = nil,
                            credential: SlackCredential) async throws -> SlackPostedMessage {
        var parameters = ["channel": channel, "text": text]
        parameters["thread_ts"] = threadTS
        return try Self.decode(SlackPostedMessage.self,
                               try await call("chat.postMessage", parameters: parameters, credential: credential))
    }
}
