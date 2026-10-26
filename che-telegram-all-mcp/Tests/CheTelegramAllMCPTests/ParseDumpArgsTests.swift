import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `parseDumpChatToMarkdownArgs` (#13): required arguments, defaults and caps.
/// Moved out of ServerHandlerLogicTests.swift (#26) without changes.
final class ParseDumpArgsTests: XCTestCase {

    // MARK: - #13: parseDumpChatToMarkdownArgs

    func testDumpRequiresChatId() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "output_path": .string("/tmp/x.md"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
    }

    func testDumpRequiresOutputPath() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "output_path is required")
        }
    }

    func testDumpDefaultMaxMessagesIs5000() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
        XCTAssertEqual(parsed.outputPath, "/tmp/x.md")
        XCTAssertEqual(parsed.maxMessages, 5000,
                       "default max_messages for dump_chat_to_markdown is 5000 (different from get_chat_history)")
    }

    func testDumpDefaultSelfLabel() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.selfLabel, "我", "default self_label is 我")
    }

    func testDumpExplicitSelfLabel() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "self_label": .string("Alice"),
        ])
        XCTAssertEqual(parsed.selfLabel, "Alice")
    }

    /// Boundary parity with #15-C2 — dump handler must enforce the same
    /// upward cap. Without this, future cap policy changes in
    /// `validateMaxMessagesCap` could silently drift here.
    func testDumpMaxMessagesAt10001Rejected() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(10_001),
        ]))
    }

    func testDumpMaxMessagesAt10000Accepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(10_000),
        ])
        XCTAssertEqual(parsed.maxMessages, 10_000)
    }

    /// Symmetric downward boundary parity with #15 DA finding.
    func testDumpMaxMessagesAt9999Accepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(9_999),
        ])
        XCTAssertEqual(parsed.maxMessages, 9_999)
    }

    func testDumpMaxMessagesRejectsZeroOrNegative() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(0),
        ]))
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(-1),
        ]))
    }
}
