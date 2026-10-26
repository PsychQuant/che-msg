import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// The #33 grouped-id parsers: `parseChatMessageIds`, `parseChatUserIds`, `parseChatForwardIds`, `parseSendMessageIds`.
/// Split out of ServerHandlerLogicTests.swift (#26).
final class ParseGroupedIdsTests: XCTestCase {

    // MARK: - #33: parseChatMessageIds (pin_message / unpin_message / edit_message)

    func testParseChatMessageIdsRejectsJunkChatId() {
        XCTAssertThrowsError(try parseChatMessageIds([
            "chat_id": .string("x"), "message_id": .int(5),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"x\"")
        }
    }

    /// chat_id valid → message_id is the field reported (per-field message, #33
    /// supersedes the combined "chat_id and message_id are required").
    func testParseChatMessageIdsRejectsJunkMessageId() {
        XCTAssertThrowsError(try parseChatMessageIds([
            "chat_id": .int(1), "message_id": .string("m"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "message_id must be an integer; got \"m\"")
        }
    }

    func testParseChatMessageIdsThrowsRequiredOnAbsentMessageId() {
        XCTAssertThrowsError(try parseChatMessageIds(["chat_id": .int(1)])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description, "message_id is required")
        }
    }

    func testParseChatMessageIdsValid() throws {
        let ids = try parseChatMessageIds(["chat_id": .int(7), "message_id": .int(9)])
        XCTAssertEqual(ids.chatId, 7)
        XCTAssertEqual(ids.messageId, 9)
    }

    // MARK: - #33: parseChatUserIds (add_chat_member)

    func testParseChatUserIdsRejectsJunkUserId() {
        XCTAssertThrowsError(try parseChatUserIds([
            "chat_id": .int(1), "user_id": .string("u"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "user_id must be an integer; got \"u\"")
        }
    }

    func testParseChatUserIdsValid() throws {
        let ids = try parseChatUserIds(["chat_id": .int(3), "user_id": .int(4)])
        XCTAssertEqual(ids.chatId, 3)
        XCTAssertEqual(ids.userId, 4)
    }

    // MARK: - #33: parseChatForwardIds (forward_messages)

    func testParseChatForwardIdsRejectsJunkFromChatId() {
        XCTAssertThrowsError(try parseChatForwardIds([
            "chat_id": .int(1), "from_chat_id": .string("f"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "from_chat_id must be an integer; got \"f\"")
        }
    }

    // MARK: - #33: parseSendMessageIds (send_message — chat_id req + optional reply_to)

    func testParseSendMessageIdsRejectsJunkChatId() {
        XCTAssertThrowsError(try parseSendMessageIds(["chat_id": .string("x")])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"x\"")
        }
    }

    /// #33 behavior change: junk reply_to_message_id now THROWS instead of
    /// silently dropping the reply target.
    func testParseSendMessageIdsRejectsJunkReplyTo() {
        XCTAssertThrowsError(try parseSendMessageIds([
            "chat_id": .int(1), "reply_to_message_id": .string("junk"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "reply_to_message_id must be an integer; got \"junk\"")
        }
    }

    /// #33: the legitimate "no reply" case — absent reply_to → nil (unchanged).
    /// Mutation guard for the optional branch: swapping int64ArgValueStrict for
    /// requiredInt64 on reply_to would throw here instead of returning nil.
    func testParseSendMessageIdsAbsentReplyToIsNil() throws {
        let ids = try parseSendMessageIds(["chat_id": .int(1)])
        XCTAssertEqual(ids.chatId, 1)
        XCTAssertNil(ids.replyToMessageId)
    }

    /// #33: explicit .null reply_to → nil (treated as absent).
    func testParseSendMessageIdsNullReplyToIsNil() throws {
        let ids = try parseSendMessageIds(["chat_id": .int(1), "reply_to_message_id": .null])
        XCTAssertNil(ids.replyToMessageId)
    }

    /// #33: valid reply_to → populated.
    func testParseSendMessageIdsValidReplyTo() throws {
        let ids = try parseSendMessageIds(["chat_id": .int(1), "reply_to_message_id": .int(99)])
        XCTAssertEqual(ids.replyToMessageId, 99)
    }

    // MARK: - #33 verify follow-ups (Codex + security reviewer nits)

    /// Codex verify nit #3: `parseChatForwardIds` valid-mapping test, for parity
    /// with the other grouped parsers (the others had a valid-path assertion).
    /// Locks chat_id→chatId / from_chat_id→fromChatId (no swap).
    func testParseChatForwardIdsValid() throws {
        let ids = try parseChatForwardIds(["chat_id": .int(3), "from_chat_id": .int(4)])
        XCTAssertEqual(ids.chatId, 3)
        XCTAssertEqual(ids.fromChatId, 4)
    }
}
