/// The TDLib API constructor name of a message content, from the internal
/// `MessageContentType` number the cache stores (PsychQuant/che-msg#118).
///
/// Read case by case from `get_message_content_object` in `td/telegram/MessageContent.cpp`
/// of TDLib 1.8.60 (cb863c16), the TDLib the package pins; `Invoice` from
/// `InputInvoice::get_message_invoice_object`. The table is closed: it names only the
/// internal types that function turns into one constructor whatever the payload and
/// that the reader does not map to a named `type`.
///
/// Nil for the reader's named types, for the 12 internal types with more than one constructor —
/// picked by the payload for `ChatChangePhoto` 13, `ChatJoinedByLink` 17, `PaymentSuccessful` 30,
/// `Dice` 41, `GroupCall` 43, `TopicEdit` 50, `SuggestProfilePhoto` 51, `RequestedDialog` 53,
/// `DialogShared` 66, `StarGiftUnique` 72 and `SuggestedPostApproval` 82, and by whether the chat
/// is a broadcast channel for `PaidMessagesPrice` 74 — and for a value TDLib 1.8.60 does not
/// define. The reader does not decode those payloads or look up the chat while decoding a
/// message, so for those it omits `content_type`.
enum TDLibContentTypeNames {
    static func apiName(forContentType type: Int32) -> String? {
        switch type {
        case 8: return "messageContact"
        case 10: return "messageVenue"
        case 11: return "messageBasicGroupChatCreate"                 // ChatCreate
        case 12: return "messageChatChangeTitle"
        case 14: return "messageChatDeletePhoto"
        case 15: return "messageUnsupported"                          // ChatDeleteHistory
        case 16: return "messageChatAddMembers"                       // ChatAddUsers
        case 18: return "messageChatDeleteMember"                     // ChatDeleteUser
        case 19: return "messageChatUpgradeTo"                        // ChatMigrateTo
        case 20: return "messageSupergroupChatCreate"                 // ChannelCreate
        case 21: return "messageChatUpgradeFrom"                      // ChannelMigrateFrom
        case 22: return "messagePinMessage"
        case 23: return "messageGame"
        case 24: return "messageGameScore"
        case 25: return "messageScreenshotTaken"
        case 26: return "messageChatSetMessageAutoDeleteTime"         // ChatSetTtl
        case 27: return "messageUnsupported"
        case 28: return "messageCall"
        case 29: return "messageInvoice"
        case 32: return "messageContactRegistered"
        case 33: return "messageExpiredPhoto"
        case 34: return "messageExpiredVideo"
        case 36: return "messageCustomServiceAction"
        case 37: return "messageBotWriteAccessAllowed"                // WebsiteConnected
        case 38: return "messagePassportDataSent"
        case 39: return "messagePassportDataReceived"
        case 42: return "messageProximityAlertTriggered"
        case 44: return "messageInviteVideoChatParticipants"          // InviteToGroupCall
        case 45: return "messageChatSetTheme"
        case 46: return "messageWebAppDataSent"                       // WebViewDataSent
        case 47: return "messageWebAppDataReceived"                   // WebViewDataReceived
        case 48: return "messageGiftedPremium"                        // GiftPremium
        case 49: return "messageForumTopicCreated"                    // TopicCreate
        case 52: return "messageBotWriteAccessAllowed"                // WriteAccessAllowed
        case 54: return "messageBotWriteAccessAllowed"                // WebViewWriteAccessAllowed
        case 55: return "messageChatSetBackground"                    // SetBackground
        case 56: return "messageStory"
        case 57: return "messageBotWriteAccessAllowed"                // WriteAccessAllowedByRequest
        case 58: return "messagePremiumGiftCode"                      // GiftCode
        case 59: return "messageGiveaway"
        case 60: return "messageGiveawayCreated"                      // GiveawayLaunch
        case 61: return "messageGiveawayCompleted"                    // GiveawayResults
        case 62: return "messageGiveawayWinners"
        case 63: return "messageExpiredVideoNote"
        case 64: return "messageExpiredVoiceNote"
        case 65: return "messageChatBoost"                            // BoostApply
        case 67: return "messagePaidMedia"
        case 68: return "messagePaymentRefunded"
        case 69: return "messageGiftedStars"                          // GiftStars
        case 70: return "messageGiveawayPrizeStars"                   // PrizeStars
        case 71: return "messageGift"                                 // StarGift
        case 73: return "messagePaidMessagesRefunded"
        case 75: return "messageGroupCall"                            // ConferenceCall
        case 76: return "messageChecklist"                            // ToDoList
        case 77: return "messageChecklistTasksDone"                   // TodoCompletions
        case 78: return "messageChecklistTasksAdded"                  // TodoAppendTasks
        case 79: return "messageGiftedTon"                            // GiftTon
        case 80: return "messageSuggestedPostPaid"                    // SuggestedPostSuccess
        case 81: return "messageSuggestedPostRefunded"                // SuggestedPostRefund
        case 83: return "messageSuggestBirthdate"                     // SuggestBirthday
        case 84: return "messageUpgradedGiftPurchaseOffer"            // StarGiftPurchaseOffer
        case 85: return "messageUpgradedGiftPurchaseOfferRejected"    // StarGiftPurchaseOfferDeclined
        default: return nil
        }
    }
}
