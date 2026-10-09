import XCTest
@testable import TelegramAllLib

/// Covers task 3.4 and the message part of "Undecodable records are reported,
/// not guessed" (telegram-local-reader; PsychQuant/che-msg#58): messages
/// decoded from hand-built `messages.data` bytes laid out in the order of
/// TDLib 1.8.60 `MessagesManager::Message::parse` and `parse_message_content`.
final class LocalReaderMessageDecodingTests: XCTestCase {

    private enum Content {
        case text(String)
        case photo
        case contentType(Int32)
    }

    /// The fields a test sets; everything else is absent.
    private struct Spec {
        var version: Int32 = 57
        var messageId: Int64 = 5_242_880
        var senderUserId: Int64? = 1001
        var date: Int32 = 1_760_000_000
        var outgoing = false
        var editDate: Int32?
        var randomId: Int64?
        var viaBotUserId: Int64?
        var viewCount: Int32?
        var authorSignature: String?
        var senderDialogId: Int64?
        var localThreadMessageIds: [Int64]?
        var forwardInfo = false          // flags3 bit 12
        var replyInfo = false            // flags2 bit 15
        var extraFlags4: UInt32 = 0
        var content: Content = .text("hello")
    }

    /// Flag bits from `Message::parse`: flags1 is_outgoing 1, has_sender 10,
    /// has_edit_date 11, has_random_id 12, is_via_bot 16, has_view_count 17,
    /// has_author_signature 20, has_flags2 29; flags2 has_reply_info 15,
    /// has_sender_dialog_id 16, has_local_thread_message_ids 20, has_flags3 29;
    /// flags3 has_forward_info 12, has_flags4 29.
    private func bytes(_ m: Spec) -> [UInt8] {
        var f1: UInt32 = 0, f2: UInt32 = 0, f3: UInt32 = 0
        let f4 = m.extraFlags4
        if m.outgoing { f1 |= flags(1) }
        if m.senderUserId != nil { f1 |= flags(10) }
        if m.editDate != nil { f1 |= flags(11) }
        if m.randomId != nil { f1 |= flags(12) }
        if m.viaBotUserId != nil { f1 |= flags(16) }
        if m.viewCount != nil { f1 |= flags(17) }
        if m.authorSignature != nil { f1 |= flags(20) }
        if m.replyInfo { f2 |= flags(15) }
        if m.senderDialogId != nil { f2 |= flags(16) }
        if m.localThreadMessageIds != nil { f2 |= flags(20) }
        if m.forwardInfo { f3 |= flags(12) }
        let hasF4 = f4 != 0, hasF3 = f3 != 0 || hasF4, hasF2 = f2 != 0 || hasF3
        if hasF2 { f1 |= flags(29) }
        if hasF3 { f2 |= flags(29) }
        if hasF4 { f3 |= flags(29) }

        var w = TLWriter()
        w.int32(m.version)
        w.uint32(f1)
        if hasF2 { w.uint32(f2) }
        if hasF3 { w.uint32(f3) }
        if hasF4 { w.uint32(f4) }
        w.int64(m.messageId)
        if let sender = m.senderUserId {
            if m.version >= 33 { w.int64(sender) } else { w.int32(Int32(sender)) }
        }
        w.int32(m.date)
        if let edit = m.editDate { w.int32(edit) }
        if let random = m.randomId { w.int64(random) }
        if m.forwardInfo { fakeTextContent(&w) }     // stands in for MessageForwardInfo
        if let bot = m.viaBotUserId { w.int64(bot) }
        if let views = m.viewCount { w.int32(views) }
        if m.replyInfo { fakeTextContent(&w) }     // stands in for MessageReplyInfo
        if let signature = m.authorSignature { w.string(signature) }
        if let senderDialog = m.senderDialogId { w.int64(senderDialog) }
        if let threadIds = m.localThreadMessageIds {
            w.int32(Int32(threadIds.count))
            threadIds.forEach { w.int64($0) }
        }
        switch m.content {
        case .text(let text):
            w.int32(0)                                    // MessageContentType::Text
            if m.version >= 49 { w.uint32(flags(0)) }    // has_web_page_id
            w.string(text)
            w.int32(0)                                    // entities: empty vector
            w.int64(0)                                    // web_page_id
        case .photo:
            w.int32(4)                                    // MessageContentType::Photo
            w.int64(0x5555_5555_5555_5555)                // Photo; never read
        case .contentType(let type):
            w.int32(type)
        }
        return w.bytes
    }

    /// Bytes that read as a text message "guess". They stand where a field the
    /// reader does not support begins, so a reader that skipped past that field
    /// instead of stopping would report "guess" as the text.
    private func fakeTextContent(_ w: inout TLWriter) {
        w.int32(0); w.uint32(flags(0)); w.string("guess"); w.int32(0); w.int64(0)
    }

    private func decode(_ m: Spec, chatId: Int64 = 777, messageId: Int64? = nil,
                        senderColumn: Int64? = 1001, data: [UInt8]? = nil) -> LocalMessage {
        TDLibMessageDecoder.message(chatId: chatId, messageId: messageId ?? m.messageId,
                                    senderColumn: senderColumn, data: data ?? bytes(m))
    }

    private func json(_ message: LocalMessage) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message.dictionary, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Decoded messages

    /// Spec example "one text message".
    func testTextMessageMatchesTheSpecExample() throws {
        XCTAssertEqual(try json(decode(Spec())),
                       #"{"chat_id":777,"date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"text":"hello","type":"text"}"#)
    }

    func testNonASCIIOutgoingText() {
        let message = decode(Spec(outgoing: true, content: .text("你好，世界 👋")))
        XCTAssertEqual(message.text, "你好，世界 👋")
        XCTAssertEqual(message.isOutgoing, true)
        XCTAssertEqual(message.type, .text)
    }

    func testOptionalFieldsBeforeTheContentAreSkipped() {
        let spec = Spec(editDate: 1_760_000_100, randomId: -42, viaBotUserId: 9_000_001, viewCount: 12,
                        authorSignature: "編輯部", senderDialogId: -1_000_000_000_042,
                        localThreadMessageIds: [1_048_576, 2_097_152])
        let message = decode(spec, chatId: -1_000_000_000_042, senderColumn: -1_000_000_000_042)
        XCTAssertEqual(message, LocalMessage(id: 5_242_880, chatId: -1_000_000_000_042, date: 1_760_000_000,
                                             sender: .chat(-1_000_000_000_042), isOutgoing: false,
                                             type: .text, text: "hello"))
    }

    func testTextBeforeAddMessageTextFlagsHasNoTextFlagWord() {
        XCTAssertEqual(decode(Spec(version: 48)).text, "hello")
    }

    func testSenderBefore64BitIdsIsAnInt32() {
        XCTAssertEqual(decode(Spec(version: 32)).text, "hello")
    }

    func testPhotoHasItsTypeButNoCaption() throws {
        XCTAssertEqual(try json(decode(Spec(content: .photo))),
                       #"{"chat_id":777,"date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"type":"photo"}"#)
    }

    func testContentTypesMapToTheTDLibModeNames() {
        let expected: [(Int32, LocalMessage.Kind)] = [
            (1, .animation), (2, .other), (3, .document), (5, .sticker), (6, .video), (7, .voiceNote),
            (9, .location), (16, .other), (31, .videoNote), (35, .location), (40, .poll), (85, .other),
        ]
        for (contentType, kind) in expected {
            XCTAssertEqual(decode(Spec(content: .contentType(contentType))).type, kind, "content type \(contentType)")
        }
    }

    func testMissingSenderColumnOmitsTheSender() throws {
        XCTAssertFalse(try json(decode(Spec(), senderColumn: nil)).contains("sender"))
    }

    // MARK: - Undecodable messages

    /// Forwarded and channel-comment messages stop before their content: the
    /// fields before that point are kept, the content is not guessed.
    func testForwardedMessageIsUnknownWithoutText() throws {
        XCTAssertEqual(try json(decode(Spec(forwardInfo: true))),
                       #"{"chat_id":777,"date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"type":"unknown"}"#)
    }

    func testChannelCommentInfoMakesTheMessageUnknown() {
        let message = decode(Spec(replyInfo: true))
        XCTAssertEqual(message.type, .unknown)
        XCTAssertNil(message.text)
        XCTAssertEqual(message.sender, .user(1001))
    }

    /// Scenario "Message with an unknown content flag": a flag bit TDLib 1.8.60
    /// does not define leaves only the table columns.
    func testUnrecognisedFlagLeavesOnlyTheColumns() throws {
        XCTAssertEqual(try json(decode(Spec(extraFlags4: flags(10)))),
                       #"{"chat_id":777,"id":5242880,"sender":{"type":"user","user_id":1001},"type":"unknown"}"#)
    }

    func testMessageIdThatDisagreesWithTheColumnLeavesOnlyTheColumns() {
        let message = decode(Spec(), messageId: 5_242_881)
        XCTAssertEqual(message, LocalMessage(id: 5_242_881, chatId: 777, date: nil, sender: .user(1001),
                                             isOutgoing: nil, type: .unknown, text: nil))
    }

    func testTruncatedTextIsUnknown() {
        let full = bytes(Spec(content: .text("a longer message body")))
        let message = decode(Spec(), data: Array(full.prefix(full.count - 20)))
        XCTAssertEqual(message.type, .unknown)
        XCTAssertNil(message.text)
        XCTAssertEqual(message.date, 1_760_000_000)
    }

    func testTextThatIsNotUTF8IsUnknown() {
        var spec = Spec()
        spec.content = .text("x")
        var data = bytes(spec)
        // The date's bytes contain 0x78 too; only zero padding and zero-valued
        // fields follow the text, so its byte is the last "x".
        let textByte = data.lastIndex(of: UInt8(ascii: "x"))!
        data[textByte] = 0xFF
        XCTAssertEqual(decode(spec, data: data).type, .unknown)
    }

    func testRecordNewerThanTDLib1860LeavesOnlyTheColumns() {
        let message = decode(Spec(version: 58))
        XCTAssertEqual(message.type, .unknown)
        XCTAssertNil(message.date)
    }

    func testContentTypeOutsideTDLib1860IsUnknown() {
        XCTAssertEqual(decode(Spec(content: .contentType(999))).type, .unknown)
    }

    func testEmptyDataIsUnknown() {
        XCTAssertEqual(decode(Spec(), data: []).type, .unknown)
    }
}
