import Foundation

/// The names Slack puts on a user profile. Either may be an empty string:
/// many users never set a display name.
public struct SlackProfileNames: Equatable, Sendable, Decodable {
    public let displayName: String?
    public let realName: String?

    public init(displayName: String? = nil, realName: String? = nil) {
        self.displayName = displayName
        self.realName = realName
    }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case realName = "real_name"
    }
}

/// One message from `conversations.history` or `conversations.replies`.
/// Only `ts` is required; a field of the wrong JSON type fails the whole
/// answer rather than being dropped.
public struct SlackMessage: Equatable, Sendable, Decodable {
    public let ts: String
    /// The sender's user id; absent on most bot messages.
    public let user: String?
    public let botID: String?
    /// The name Slack attaches to bot messages and search matches.
    public let username: String?
    public let text: String?
    public let threadTS: String?
    /// Present on a thread parent.
    public let replyCount: Int?
    /// The ts of a thread parent's newest reply, present on a parent.
    public let latestReply: String?
    public let subtype: String?
    /// The sender's names, when Slack sends them along with the message.
    public let userProfile: SlackProfileNames?
    /// Files attached to the message, as Slack describes them; absent when
    /// there are none.
    public let files: [SlackFile]?

    public init(ts: String, user: String? = nil, botID: String? = nil, username: String? = nil, text: String? = nil,
                threadTS: String? = nil, replyCount: Int? = nil, subtype: String? = nil,
                userProfile: SlackProfileNames? = nil, files: [SlackFile]? = nil, latestReply: String? = nil) {
        self.ts = ts
        self.user = user
        self.botID = botID
        self.username = username
        self.text = text
        self.threadTS = threadTS
        self.replyCount = replyCount
        self.latestReply = latestReply
        self.subtype = subtype
        self.userProfile = userProfile
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case ts, user, username, text, subtype, files
        case botID = "bot_id"
        case threadTS = "thread_ts"
        case replyCount = "reply_count"
        case latestReply = "latest_reply"
        case userProfile = "user_profile"
    }

    /// A name for the sender taken from the message itself, without asking
    /// Slack: the profile's display name, else its real name, else
    /// `username`; nil when none is a non-empty string.
    public var senderName: String? {
        [userProfile?.displayName, userProfile?.realName, username].firstNonEmpty
    }
}

/// A file attached to a message: only what the archive writes about it.
/// Every field is optional, since Slack sends a hidden or deleted file with
/// little more than its id. Nothing is downloaded.
public struct SlackFile: Equatable, Sendable, Decodable {
    public let id: String?
    public let name: String?
    public let title: String?
    public let permalink: String?

    public init(id: String? = nil, name: String? = nil, title: String? = nil, permalink: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.permalink = permalink
    }
}

/// One conversation from `users.conversations`. Only `id` is required; a
/// missing flag counts as false.
public struct SlackConversation: Equatable, Sendable, Decodable {
    /// The four kinds, named as Slack's `types` parameter names them.
    public enum Kind: String, Sendable {
        case publicChannel = "public_channel"
        case privateChannel = "private_channel"
        case mpim
        case im
    }

    public let id: String
    /// Absent for a direct message.
    public let name: String?
    /// For a direct message, the other user's id.
    public let user: String?
    public let kind: Kind

    public init(id: String, name: String? = nil, user: String? = nil, kind: Kind) {
        self.id = id
        self.name = name
        self.user = user
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, name, user
        case isIM = "is_im"
        case isMPIM = "is_mpim"
        case isPrivate = "is_private"
        case isGroup = "is_group"
    }

    /// Kind, in order: `is_im`, then `is_mpim`, then `is_private` or the
    /// legacy `is_group`, else a public channel.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        func flag(_ key: CodingKeys) throws -> Bool { try container.decodeIfPresent(Bool.self, forKey: key) ?? false }
        if try flag(.isIM) {
            kind = .im
        } else if try flag(.isMPIM) {
            kind = .mpim
        } else if try flag(.isPrivate) || flag(.isGroup) {
            kind = .privateChannel
        } else {
            kind = .publicChannel
        }
    }
}

/// The conversations the user is a member of.
public struct SlackConversationList: Equatable, Sendable {
    public let conversations: [SlackConversation]
    /// True when the page limit stopped the walk while Slack still offered
    /// a cursor.
    public let hasMore: Bool
}

/// A user from `users.info`. Only `id` is required; nothing else from the
/// profile (email, phone) is decoded.
public struct SlackUser: Equatable, Sendable, Decodable {
    public let id: String
    /// The handle, e.g. `alice.chen`.
    public let name: String?
    public let realName: String?
    public let isBot: Bool?
    public let profile: SlackProfileNames?

    public init(id: String, name: String? = nil, realName: String? = nil, isBot: Bool? = nil,
                profile: SlackProfileNames? = nil) {
        self.id = id
        self.name = name
        self.realName = realName
        self.isBot = isBot
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case id, name, profile
        case realName = "real_name"
        case isBot = "is_bot"
    }

    /// The profile's display name, as Slack has it (possibly empty).
    public var displayName: String? { profile?.displayName }

    /// The real name: the user's own when non-empty, else its profile's.
    public var fullName: String? { [realName, profile?.realName].firstNonEmpty ?? realName }

    /// The name Slack's own client shows: the display name, else the real
    /// name, else the handle; nil when none is a non-empty string.
    public var preferredName: String? { [displayName, realName, profile?.realName, name].firstNonEmpty }
}

/// One match from `search.messages`. Only `ts` is required.
public struct SlackSearchMatch: Equatable, Sendable, Decodable {
    public struct Channel: Equatable, Sendable, Decodable {
        public let id: String?
        /// For a direct message, Slack sends the other user's id here.
        public let name: String?

        public init(id: String? = nil, name: String? = nil) {
            self.id = id
            self.name = name
        }
    }

    public let ts: String
    public let channel: Channel?
    public let user: String?
    public let username: String?
    public let text: String?
    public let permalink: String?

    public init(ts: String, channel: Channel? = nil, user: String? = nil, username: String? = nil,
                text: String? = nil, permalink: String? = nil) {
        self.ts = ts
        self.channel = channel
        self.user = user
        self.username = username
        self.text = text
        self.permalink = permalink
    }
}

/// What `search.messages` found: the matches on the first page, and the
/// total Slack reports.
public struct SlackSearchResult: Equatable, Sendable {
    public let matches: [SlackSearchMatch]
    public let total: Int?
}

/// One page of messages, in Slack's order.
public struct SlackMessagePage: Equatable, Sendable {
    public let messages: [SlackMessage]
    /// True when Slack says more messages exist past this page.
    public let hasMore: Bool
    /// The cursor that fetches the next `conversations.history` page; nil
    /// when Slack sent none.
    public let nextCursor: String?

    init(messages: [SlackMessage], hasMore: Bool, nextCursor: String? = nil) {
        self.messages = messages
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

/// The `response_metadata.next_cursor` every cursor-paginated answer
/// carries; an empty string means no further page.
struct SlackResponseMetadata: Decodable {
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case nextCursor = "next_cursor" }

    static func cursor(_ metadata: SlackResponseMetadata?) -> String? {
        guard let cursor = metadata?.nextCursor, !cursor.isEmpty else { return nil }
        return cursor
    }
}

extension Array where Element == String? {
    /// The first element that is a non-empty string.
    var firstNonEmpty: String? {
        for case let value? in self where !value.isEmpty { return value }
        return nil
    }
}
