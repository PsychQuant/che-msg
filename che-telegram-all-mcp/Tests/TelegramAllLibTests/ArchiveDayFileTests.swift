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

    /// Signs inside the digit fields are not numbers (Int("-1") parses, so check digits).
    func testOffsetFieldsMustBeDigits() {
        for text in ["+-1:00", "-+1:00", "+08:-1", "+08:+1", "+٠٨:00"] {
            XCTAssertNil(ArchiveDayFile.offsetSeconds(text), text)
        }
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("+08:00"), 28_800)
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("-03:30"), -12_600)
    }

    // MARK: - Verify round 1 (#69)

    /// Foundation's TimeZone(secondsFromGMT:) stops at ±18 hours.
    func testOffsetsBeyondEighteenHoursAreRefused() {
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("+18:00"), 64_800)
        XCTAssertEqual(ArchiveDayFile.offsetSeconds("-18:00"), -64_800)
        for text in ["+18:01", "+19:00", "-23:59"] { XCTAssertNil(ArchiveDayFile.offsetSeconds(text), text) }
    }

    /// A body line shaped like a block header cannot pass for another speaker.
    func testHeaderShapedBodyLineIsEscaped() {
        let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Alex",
                               body: "ok\n**09:00 Manager**：\nI approve\n**重要** 事項")
        let out = ArchiveDayFile.render(chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        XCTAssertTrue(out.contains("\n\\**09:00 Manager**：\n"), out)
        XCTAssertTrue(out.contains("\n**重要** 事項\n"), out)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(out).map(\.id), [10])
    }

    /// Merging into a day file written at another offset is refused; nothing is changed.
    func testMergeAtAnotherOffsetIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dayfile-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: "a")
        _ = try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        let before = try Data(contentsOf: dir.appendingPathComponent("2026-10-11.md"))
        let n = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
        XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+09:00",
                                                      messages: [n])) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .offsetMismatch(existing: "+08:00", requested: "+09:00"))
            XCTAssertTrue(error.localizedDescription.contains("utc_offset"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("2026-10-11.md")), before)
    }

    /// Archives hold other people's messages: owner-only permissions.
    func testDayFilesAreOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dayfile-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let chatDir = dir.appendingPathComponent("1")
        let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: "a")
        _ = try ArchiveDayFile.write(directory: chatDir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        let fm = FileManager.default
        XCTAssertEqual((try fm.attributesOfItem(atPath: chatDir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let file = chatDir.appendingPathComponent("2026-10-11.md").path
        XCTAssertEqual((try fm.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // A merge keeps the mode.
        let n = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
        _ = try ArchiveDayFile.write(directory: chatDir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [n])
        XCTAssertEqual((try fm.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Verify round 2 (#69)

    func testOffsetsCompareBySecondsAndUnreadableOffsetsAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dayfile-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
        // -00:00 and +00:00 are the same offset.
        try Data("---\nchat_id: 1\ndate: 2026-10-11\nutc_offset: \"-00:00\"\n---\n\n".utf8)
            .write(to: dir.appendingPathComponent("2026-10-11.md"))
        XCTAssertNoThrow(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+00:00"))
        XCTAssertNoThrow(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+00:00", messages: [m]))
        // A day file without a readable offset cannot be merged safely.
        try Data("# notes\nutc_offset: \"+99:99\"\n".utf8).write(to: dir.appendingPathComponent("2026-10-12.md"))
        XCTAssertThrowsError(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+00:00")) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .unreadableOffset(day: "2026-10-12"))
            XCTAssertFalse(error.localizedDescription.contains("+99:99"), error.localizedDescription)
        }
    }

    func testHeaderLikeLinesAreEscapedLoosely() {
        for line in ["**9:00 X**：", "**09:00 X**: ", "**09:00 X**： ", "**12:30 會議**"] {
            let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: line)
            let out = ArchiveDayFile.render(chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
            XCTAssertTrue(out.contains("\n\\" + line + "\n"), line)
        }
    }

    // MARK: - Verify round 3 (#69)

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dayfile-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Only files named like a day are day files; notes left in the chat directory are ignored.
    func testOnlyDateNamedFilesAreChecked() throws {
        let dir = try scratchDir()
        try Data("my notes".utf8).write(to: dir.appendingPathComponent("notes.md"))
        try Data("---\ntitle: x\n---\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try Data("---\nchat_id: 1\ndate: 2026-10-11\nutc_offset: \"+08:00\"\n---\n\n".utf8)
            .write(to: dir.appendingPathComponent("2026-10-11.md"))
        XCTAssertNoThrow(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00"))
    }

    /// The tool writes LF only; a day file with CRLF frontmatter was edited elsewhere and is refused.
    func testCRLFDayFileIsRefused() throws {
        let dir = try scratchDir()
        try Data("---\r\nchat_id: 1\r\ndate: 2026-10-11\r\nutc_offset: \"+08:00\"\r\n---\r\n\r\n".utf8)
            .write(to: dir.appendingPathComponent("2026-10-11.md"))
        XCTAssertThrowsError(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00")) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .unreadableOffset(day: "2026-10-11"))
        }
        let m = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
        XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                      messages: [m]))
    }

    /// A day file that cannot be opened is not skipped.
    func testUnopenableDayFileIsRefused() throws {
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("2026-10-11.md")
        try Data("---\nchat_id: 1\ndate: 2026-10-11\nutc_offset: \"+08:00\"\n---\n\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00")) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .unreadableOffset(day: "2026-10-11"))
        }
    }
}
