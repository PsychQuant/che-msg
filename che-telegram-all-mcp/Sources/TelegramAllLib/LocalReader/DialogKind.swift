/// The chat a TDLib dialog id refers to, by the id ranges of TDLib 1.8.60
/// (`DialogId::get_type` in td/telegram/DialogId.cpp, limits from UserId.h,
/// ChatId and ChannelId.h).
///
/// Every range here has both bounds. TDLib checks only the lower bound of the
/// secret-chat and monoforum ranges, so it also assigns a type to the two
/// boundary ids -1000000000000 and -2000000000000; neither is a valid chat, and
/// here they are `none`.
enum DialogKind: Equatable {
    case user(Int64)
    case basicGroup(Int64)
    case channel(Int64)
    case secretChat(Int32)
    case none

    static let maxUserId: Int64 = (1 << 40) - 1
    static let maxChatId: Int64 = 999_999_999_999
    static let zeroChannelId: Int64 = -1_000_000_000_000
    static let maxChannelId: Int64 = 1_000_000_000_000 - (1 << 31)
    static let minMonoforumChannelId: Int64 = 1_000_000_000_000 + (1 << 31) + 1
    static let maxMonoforumChannelId: Int64 = 3_000_000_000_000
    static let zeroSecretChatId: Int64 = -2_000_000_000_000

    init(dialogId id: Int64) {
        switch id {
        case 1...Self.maxUserId:
            self = .user(id)
        case -Self.maxChatId ... -1:
            self = .basicGroup(-id)
        case (Self.zeroChannelId - Self.maxChannelId)...(Self.zeroChannelId - 1),
             (Self.zeroChannelId - Self.maxMonoforumChannelId)...(Self.zeroChannelId - Self.minMonoforumChannelId):
            self = .channel(Self.zeroChannelId - id)
        case (Self.zeroSecretChatId + Int64(Int32.min))...(Self.zeroSecretChatId + Int64(Int32.max))
            where id != Self.zeroSecretChatId:
            self = .secretChat(Int32(id - Self.zeroSecretChatId))
        default:
            self = .none
        }
    }

    /// The key of the chat's record in the `common` table
    /// (`get_user_database_key`, `get_chat_database_key`,
    /// `get_channel_database_key`, `get_secret_chat_database_key`).
    var recordKey: String? {
        switch self {
        case .user(let id): return "us\(id)"
        case .basicGroup(let id): return "gr\(id)"
        case .channel(let id): return "ch\(id)"
        case .secretChat(let id): return "sc\(id)"
        case .none: return nil
        }
    }
}
