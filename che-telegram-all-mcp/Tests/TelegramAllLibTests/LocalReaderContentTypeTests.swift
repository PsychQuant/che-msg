import CTDLibSQLite
import XCTest
@testable import TelegramAllLib

/// The `type` and `content_type` of messages answered from TDLib's local cache
/// (telegram-local-reader, "Reader answers five tools with the TDLib-mode JSON fields";
/// telegram-chat-archive, "Archive from the local cache"; PsychQuant/che-msg#118).
///
/// The expected names are read case by case from `get_message_content_object` in
/// `td/telegram/MessageContent.cpp` at TDLib cb863c16 (1.8.60), the TDLib the package pins;
/// `Invoice` from `InputInvoice::get_message_invoice_object`.
final class LocalReaderContentTypeTests: XCTestCase {

    /// The 62 internal content types that `get_message_content_object` turns into one API
    /// constructor whatever the payload, and are not one of the reader's named types.
    static let expectedNames: [Int32: String] = [
        8: "messageContact", 10: "messageVenue", 11: "messageBasicGroupChatCreate",
        12: "messageChatChangeTitle", 14: "messageChatDeletePhoto", 15: "messageUnsupported",
        16: "messageChatAddMembers", 18: "messageChatDeleteMember", 19: "messageChatUpgradeTo",
        20: "messageSupergroupChatCreate", 21: "messageChatUpgradeFrom", 22: "messagePinMessage",
        23: "messageGame", 24: "messageGameScore", 25: "messageScreenshotTaken",
        26: "messageChatSetMessageAutoDeleteTime", 27: "messageUnsupported", 28: "messageCall",
        29: "messageInvoice", 32: "messageContactRegistered", 33: "messageExpiredPhoto",
        34: "messageExpiredVideo", 36: "messageCustomServiceAction", 37: "messageBotWriteAccessAllowed",
        38: "messagePassportDataSent", 39: "messagePassportDataReceived", 42: "messageProximityAlertTriggered",
        44: "messageInviteVideoChatParticipants", 45: "messageChatSetTheme", 46: "messageWebAppDataSent",
        47: "messageWebAppDataReceived", 48: "messageGiftedPremium", 49: "messageForumTopicCreated",
        52: "messageBotWriteAccessAllowed", 54: "messageBotWriteAccessAllowed", 55: "messageChatSetBackground",
        56: "messageStory", 57: "messageBotWriteAccessAllowed", 58: "messagePremiumGiftCode",
        59: "messageGiveaway", 60: "messageGiveawayCreated", 61: "messageGiveawayCompleted",
        62: "messageGiveawayWinners", 63: "messageExpiredVideoNote", 64: "messageExpiredVoiceNote",
        65: "messageChatBoost", 67: "messagePaidMedia", 68: "messagePaymentRefunded",
        69: "messageGiftedStars", 70: "messageGiveawayPrizeStars", 71: "messageGift",
        73: "messagePaidMessagesRefunded", 75: "messageGroupCall", 76: "messageChecklist",
        77: "messageChecklistTasksDone", 78: "messageChecklistTasksAdded", 79: "messageGiftedTon",
        80: "messageSuggestedPostPaid", 81: "messageSuggestedPostRefunded", 83: "messageSuggestBirthdate",
        84: "messageUpgradedGiftPurchaseOffer", 85: "messageUpgradedGiftPurchaseOfferRejected",
    ]

    /// The internal content types with more than one API constructor: chosen by the payload, or for
    /// `PaidMessagesPrice` (74) by whether the chat is a broadcast channel.
    static let payloadDependent: Set<Int32> = [13, 17, 30, 41, 43, 50, 51, 53, 66, 72, 74, 82]

    /// The reader's named types.
    static let namedTypes: [Int32: String] = [
        1: "animation", 2: "audio", 3: "document", 4: "photo", 5: "sticker", 6: "video",
        7: "voice_note", 9: "location", 31: "video_note", 35: "location", 40: "poll",
    ]

    /// `Message::store` up to the content type: a non-text message the reader stops reading
    /// right after its type.
    static func record(id: Int64, sender: Int64, date: Int32, contentType: Int32) -> [UInt8] {
        var w = TLWriter()
        w.int32(57)
        w.uint32(flags(10))
        w.int64(id); w.int64(sender); w.int32(date)
        w.int32(contentType)
        return w.bytes
    }

    private func decoded(_ contentType: Int32) -> [String: Any] {
        TDLibMessageDecoder.message(chatId: 777, messageId: 5_242_880, senderColumn: 1001,
                                    data: Self.record(id: 5_242_880, sender: 1001, date: 1_760_000_000,
                                                      contentType: contentType)).dictionary
    }

    /// A copy of the fixture cache whose chat 777 holds one message of `contentType`.
    private func reader(id: Int64 = 5_242_880, contentType: Int32) throws -> LocalTDLibReader {
        let dir = try LocalReaderFixture.copy(for: self)
        let db = try LocalReaderFixture.openAsWriter(dir)
        defer { tdsqlite3_close(db) }
        LocalReaderFixture.putDialog(db, id: 777, order: 300, folder: 0)
        LocalReaderFixture.putCommon(db, "us777", LocalReaderRecords.user("Bob", "Chen"))
        LocalReaderFixture.putCommon(db, "us1001", LocalReaderRecords.user("Ada", "Lovelace"))
        LocalReaderFixture.putMessage(db, chat: 777, id: id, sender: 1001,
                                      data: Self.record(id: id, sender: 1001, date: 1_760_000_000, contentType: contentType))
        return LocalTDLibReader(directory: dir.path)
    }

    private func normalized(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    // spec-example: telegram-local-reader / every internal content type has its type and name
    func testEveryInternalContentTypeHasItsTypeAndName() {
        XCTAssertEqual(Self.expectedNames.count, 62)
        XCTAssertEqual(Self.payloadDependent.count, 12)
        for contentType: Int32 in 0...85 {
            // A text record carries its text after the type, so type 0 is decoded from a full text record.
            let object = contentType == 0
                ? TDLibMessageDecoder.message(chatId: 777, messageId: 5_242_880, senderColumn: 1001,
                                              data: LocalReaderRecords.message(id: 5_242_880, sender: 1001,
                                                                               date: 1_760_000_000, text: "hi")).dictionary
                : decoded(contentType)
            let type = object["type"] as? String
            let name = object["content_type"] as? String
            if contentType == 0 {
                XCTAssertEqual(type, "text", "content type 0")
                XCTAssertEqual(object["text"] as? String, "hi")
                XCTAssertNil(object["content_type"], "content type 0 has a named type and no content_type")
            } else if let named = Self.namedTypes[contentType] {
                XCTAssertEqual(type, named, "content type \(contentType)")
                XCTAssertNil(name, "content type \(contentType) has a named type and no content_type")
            } else if Self.payloadDependent.contains(contentType) {
                XCTAssertEqual(type, "other", "content type \(contentType)")
                XCTAssertNil(object["content_type"], "content type \(contentType) has more than one constructor")
            } else {
                XCTAssertEqual(type, "other", "content type \(contentType)")
                XCTAssertEqual(name, Self.expectedNames[contentType], "content type \(contentType)")
            }
        }
    }

    func testTheNameTableCoversEveryOtherValueOnce() {
        let named = Set(Self.namedTypes.keys).union([0])
        let all = Set(Self.expectedNames.keys).union(Self.payloadDependent).union(named)
        XCTAssertEqual(all, Set(0...85))
        XCTAssertTrue(Set(Self.expectedNames.keys).isDisjoint(with: Self.payloadDependent))
        XCTAssertTrue(Set(Self.expectedNames.keys).isDisjoint(with: named))
        for contentType: Int32 in 0...85 {
            XCTAssertEqual(TDLibContentTypeNames.apiName(forContentType: contentType), Self.expectedNames[contentType],
                           "content type \(contentType)")
        }
        XCTAssertNil(TDLibContentTypeNames.apiName(forContentType: -1))
        XCTAssertNil(TDLibContentTypeNames.apiName(forContentType: 86))
    }

    // spec-example: telegram-local-reader / a cached contact carries its content type
    func testACachedContactCarriesItsContentType() throws {
        let result = try reader(contentType: 8).getChatHistory(chatId: 777)
        XCTAssertEqual(try normalized(result.json),
                       #"[{"chat_id":777,"content_type":"messageContact","date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"type":"other"}]"#)
    }

    // spec-example: telegram-local-reader / a payload-dependent content type is omitted
    func testAPayloadDependentContentTypeIsOmitted() {
        let object = decoded(41)
        XCTAssertEqual(object["type"] as? String, "other")
        XCTAssertNil(object["content_type"])
    }

    // spec-example: telegram-local-reader / a cached audio message
    func testACachedAudioMessage() async throws {
        let reader = try reader(contentType: 2)
        XCTAssertEqual(try normalized(reader.getChatHistory(chatId: 777).json),
                       #"[{"chat_id":777,"date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"type":"audio"}]"#)

        let output = try LocalReaderFixture.copy(for: self).appendingPathComponent("chat.md")
        _ = try await reader.dumpChatToMarkdown(chatId: 777, outputPath: output.path)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(markdown.contains(" Ada Lovelace**：\n[audio]\n"), markdown)
        XCTAssertFalse(markdown.contains("[other]"), markdown)
    }

    // spec-example: telegram-chat-archive / cached audio counts as pending media
    func testCachedAudioCountsAsPendingMedia() async throws {
        let source = LocalCacheHistorySource(reader: try reader(id: 30, contentType: 2))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-audio-archive-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let result = try await ChatArchiver.localCache(source)
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertEqual(result.newMessages, 1)
        XCTAssertEqual(result.mediaPendingLocalCache, 1)
        // 1760000000 is 2025-10-09 16:53 at +08:00.
        let text = try String(contentsOf: dir.appendingPathComponent("777/2025-10-09.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("<!-- msg:30 -->\n<!-- provisional: local-cache -->\n**16:53 User 1001**：\n[audio](media/30/)\n\n"), text)
    }
}
