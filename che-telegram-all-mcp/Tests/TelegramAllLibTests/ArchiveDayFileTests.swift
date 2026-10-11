import XCTest
@testable import TelegramAllLib

/// telegram-chat-archive "Day file format" (PsychQuant/che-msg#69, task 1.1).
/// Synthetic messages only.
final class ArchiveDayFileTests: XCTestCase {
    /// A UTC instant built field by field, independent of the code under test.
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (y, mo, d, h, mi)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    func testOffsetParsing() {
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("+08:00"), 28_800)
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("-05:00"), -18_000)
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("+05:30"), 19_800)
        for bad in ["08:00", "+8:00", "+08", "+24:00", "+08:60", "", "UTC"] {
            XCTAssertNil(ArchiveDayFile.offsetSeconds(bad), bad)
        }
    }

    // 2026-10-11 03:00 UTC is 11:00 on the 11th at +08:00 and 22:00 on the 10th at -05:00.
    func testDayKeyFollowsTheOffset() {
        let instant = utc(2026, 10, 11, 3, 0)
        XCTAssertEqual(ArchiveDayFile.dayKey(for: instant, offsetSeconds: 28_800), "2026-10-11")
        XCTAssertEqual(ArchiveDayFile.dayKey(for: instant, offsetSeconds: -18_000), "2026-10-10")
    }

    func testBodies() {
        XCTAssertEqual(ArchiveDayFile.body(type: "text", text: "hello", caption: nil, messageId: 1), "hello")
        XCTAssertEqual(ArchiveDayFile.body(type: "photo", text: nil, caption: "menu", messageId: 5_243_904),
                       "[photo](media/5243904/) menu")
        XCTAssertEqual(ArchiveDayFile.body(type: "voice_note", text: nil, caption: nil, messageId: 6000),
                       "[voice_note](media/6000/)")
        XCTAssertEqual(ArchiveDayFile.body(type: "document", text: nil, caption: "", messageId: 7),
                       "[document](media/7/)")
        XCTAssertEqual(ArchiveDayFile.body(type: "location", text: nil, caption: nil, messageId: 8), "[location]")
        XCTAssertEqual(ArchiveDayFile.body(type: "poll", text: nil, caption: "q", messageId: 9), "[poll] q")
        for type in ["video", "audio", "video_note", "animation", "sticker"] {
            XCTAssertEqual(ArchiveDayFile.body(type: type, text: nil, caption: nil, messageId: 1), "[\(type)](media/1/)")
        }
    }

    // Example "day file" in the spec, byte for byte.
    func testDayFileExample() {
        let messages = [
            ArchiveMessage(id: 5_242_880, date: utc(2026, 10, 11, 1, 5), sender: "Alex", body: "hello"),
            ArchiveMessage(id: 5_243_904, date: utc(2026, 10, 11, 1, 7), sender: "我", body: "[photo](media/5243904/) menu"),
        ]
        let expected = """
        ---
        chat_id: 777
        date: 2026-10-11
        utc_offset: "+08:00"
        ---

        <!-- msg:5242880 -->
        **09:05 Alex**：
        hello

        <!-- msg:5243904 -->
        **09:07 我**：
        [photo](media/5243904/) menu


        """
        XCTAssertEqual(ArchiveDayFile.render(chatId: 777, day: "2026-10-11", utcOffset: "+08:00", messages: messages),
                       expected)
    }

    /// A body line that looks like an anchor must not read back as one.
    func testBodyLineThatLooksLikeAnAnchorIsEscaped() {
        let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: "<!-- msg:99 -->\nok")
        let out = ArchiveDayFile.render(chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        XCTAssertFalse(out.contains("\n<!-- msg:99 -->"), out)
        XCTAssertTrue(out.contains("\\<!-- msg:99 -->"), out)
    }

    // MARK: - Merge and idempotent rewrite (task 1.2)

    private func message(_ id: Int64, minute: Int, sender: String = "Alex", body: String? = nil) -> ArchiveMessage {
        ArchiveMessage(id: id, date: utc(2026, 10, 11, 1, minute), sender: sender, body: body ?? "m\(id)")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testParseBlocksReadsAnchorsAndIgnoresEscapedLines() {
        let content = ArchiveDayFile.render(chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: [
            message(30, minute: 0, body: "<!-- msg:99 -->"), message(50, minute: 2),
        ])
        XCTAssertEqual(ArchiveDayFile.parseBlocks(content).map(\.id), [30, 50])
    }

    // Scenario "Older messages arrive after newer ones".
    func testOlderMessagesArriveAfterNewerOnes() {
        let first = ArchiveDayFile.render(chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                          messages: [message(30, minute: 0), message(50, minute: 2)])
        let (content, added) = ArchiveDayFile.merged(existing: first, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                                     messages: [message(40, minute: 1), message(50, minute: 2)])
        XCTAssertEqual(added, [40])
        XCTAssertEqual(ArchiveDayFile.parseBlocks(content).map(\.id), [30, 40, 50])
        XCTAssertEqual(content.components(separatedBy: "<!-- msg:50 -->").count - 1, 1)
    }

    func testExistingBlocksKeepTheirExactText() {
        let existing = "---\nchat_id: 7\ndate: 2026-10-11\nutc_offset: \"+08:00\"\n---\n\n"
            + "<!-- msg:50 -->\n**09:02 Old name**：\nedited by hand\n\n"
        let (content, _) = ArchiveDayFile.merged(existing: existing, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                                 messages: [message(50, minute: 2, sender: "New name"), message(60, minute: 3)])
        XCTAssertTrue(content.contains("<!-- msg:50 -->\n**09:02 Old name**：\nedited by hand\n\n"), content)
        XCTAssertFalse(content.contains("New name"), content)
        XCTAssertTrue(content.hasSuffix("<!-- msg:60 -->\n**09:03 Alex**：\nm60\n\n"), content)
    }

    // Scenario "Re-run without new messages".
    func testRerunWithoutNewMessagesLeavesTheFileByteIdentical() throws {
        let dir = try tempDir()
        let batch = [message(30, minute: 0), message(40, minute: 1)]
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: batch), [30, 40])
        let file = dir.appendingPathComponent("2026-10-11.md")
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: batch), [])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testWriteMergesAndLeavesNoTemporaryFiles() throws {
        let dir = try tempDir()
        try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                 messages: [message(50, minute: 2)])
        try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                 messages: [message(30, minute: 0)])
        let text = try String(contentsOf: dir.appendingPathComponent("2026-10-11.md"), encoding: .utf8)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(text).map(\.id), [30, 50])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["2026-10-11.md"])
    }

    /// A sender name with a line break must not forge an anchor (commit security review, #69).
    func testSenderNameCannotForgeAnAnchor() {
        let forged = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Eve\n<!-- msg:5 -->\nx\ry",
                                    body: "hi")
        let out = ArchiveDayFile.render(chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [forged])
        XCTAssertEqual(ArchiveDayFile.parseBlocks(out).map(\.id), [10], out)
        XCTAssertTrue(out.contains("**09:00 Eve <!-- msg:5 --> x y**："), out)
    }

    /// A body with a lone carriage return keeps the anchor structure intact.
    func testLoneCarriageReturnInBody() {
        let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: "a\r<!-- msg:5 -->")
        let out = ArchiveDayFile.render(chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        XCTAssertEqual(ArchiveDayFile.parseBlocks(out).map(\.id), [10], out)
    }
}
