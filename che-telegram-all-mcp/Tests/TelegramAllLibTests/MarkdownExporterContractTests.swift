import XCTest
@testable import TelegramAllLib

/// Verifies three facets of the `dump_chat_to_markdown` contract:
///   (a) Output path validation and error reporting
///   (b) Secret chat history warning
///   (c) Self label override
///
/// Covers spec requirements:
///   - "Output path validation and error reporting"
///   - "Secret chat history warning"
///   - (portion of) "`dump_chat_to_markdown` MCP tool" — self_label parameter behavior
///
/// Corresponds to design decisions:
///   - "Markdown dump 必填 output_path，回 summary metadata"
///   - "Self 訊息用可覆寫的 label 區分"
final class MarkdownExporterContractTests: XCTestCase {

    // MARK: - (a) Output path validation

    func testValidateOutputPathThrowsWhenParentMissing() {
        let path = "/definitely/does/not/exist/\(UUID().uuidString)/chat.md"
        do {
            try validateOutputPath(path)
            XCTFail("MUST throw when parent directory is missing")
        } catch MarkdownExporter.ExportError.outputPathNotWritable(let thrownPath) {
            XCTAssertEqual(thrownPath, path,
                           "Thrown error payload MUST include the original invalid path")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testValidateOutputPathSucceedsForWritableParent() {
        let tmp = NSTemporaryDirectory()
        let path = (tmp as NSString).appendingPathComponent("test-\(UUID().uuidString).md")
        XCTAssertNoThrow(try validateOutputPath(path),
                         "Writable parent directory MUST pass validation")
    }

    // MARK: - (b) Secret chat warning in summary JSON

    func testSummaryContainsSecretChatWarningWhenFlagSet() throws {
        let json = buildSummaryJSON(
            path: "/tmp/x.md",
            messages: [],
            senderNames: [:],
            sinceDate: nil,
            untilDate: nil,
            isSecretChat: true
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let warning = obj["warning"] as? String
        XCTAssertNotNil(warning,
                        "Summary MUST include `warning` field when chat is secret")
        XCTAssertTrue(warning?.contains("secret") == true || warning?.contains("Secret") == true,
                      "Warning text MUST mention secret chat semantics")
    }

    func testSummaryOmitsWarningWhenNotSecret() throws {
        let json = buildSummaryJSON(
            path: "/tmp/x.md",
            messages: [],
            senderNames: [:],
            sinceDate: nil,
            untilDate: nil,
            isSecretChat: false
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNil(obj["warning"],
                     "Summary MUST NOT include `warning` field for non-secret chats")
    }

    func testSummaryContainsRequiredFields() throws {
        let json = buildSummaryJSON(
            path: "/tmp/out.md",
            messages: Array(repeating: ["id": Int64(1)], count: 42),
            senderNames: [10: "Alice", 20: "Bob"],
            sinceDate: nil,
            untilDate: nil,
            isSecretChat: false
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["path"] as? String, "/tmp/out.md")
        XCTAssertEqual(obj["message_count"] as? Int, 42)
        XCTAssertNotNil(obj["senders"])
        XCTAssertNotNil(obj["date_range"])
    }

    // MARK: - (c) Self label override

    private func outgoingMsg(at date: Foundation.Date) -> [String: Any] {
        [
            "id": Int64(1),
            "date": Int(date.timeIntervalSince1970),
            "sender": ["type": "user", "user_id": Int64(99)],
            "is_outgoing": true,
            "type": "text",
            "text": "hello",
        ]
    }

    func testSelfLabelDefaultsAreHonoredWhenPassedThrough() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 10, minute: 0))!
        let md = formatMarkdown(
            messages: [outgoingMsg(at: at)],
            senderNames: [:],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: at
        )
        XCTAssertTrue(md.contains("**10:00 我**"),
                      "Default self_label \"我\" MUST label outgoing messages")
    }

    func testSelfLabelOverrideChangesOutput() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 10, minute: 0))!
        let md = formatMarkdown(
            messages: [outgoingMsg(at: at)],
            senderNames: [:],
            selfLabel: "che",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: at
        )
        XCTAssertTrue(md.contains("**10:00 che**"),
                      "Overridden self_label MUST be used verbatim for outgoing messages")
        XCTAssertFalse(md.contains("**10:00 我**"),
                       "Default label MUST NOT leak when override is provided")
    }
}
