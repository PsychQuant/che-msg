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
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "text", "text": "hello"], messageId: 1), "hello")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "photo", "caption": "menu"], messageId: 5_243_904),
                       "[photo](media/5243904/) menu")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "voice_note"], messageId: 6000), "[voice_note](media/6000/)")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "document", "caption": ""], messageId: 7), "[document](media/7/)")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "location"], messageId: 8), "[location]")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "poll"], messageId: 9), "[poll]")
        XCTAssertEqual(ArchiveDayFile.body(of: [:], messageId: 9), "[other]", "a message without a type is other")
        for type in ["video", "audio", "video_note", "animation", "sticker"] {
            XCTAssertEqual(ArchiveDayFile.body(of: ["type": type], messageId: 1), "[\(type)](media/1/)")
        }
    }

    // MARK: - Poll, sticker and location details (#82)

    // Scenarios "Media type without a file", "Poll with its options", "Sticker with its emoji".
    func testBodiesKeepPollStickerAndLocationDetails() {
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "location", "latitude": 25.0478, "longitude": 121.5319], messageId: 8),
                       "[location] 25.0478,121.5319")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "poll", "question": "Lunch?", "options": ["Noodles", "Rice"]],
                                           messageId: 7000),
                       "[poll] Lunch?\n- Noodles\n- Rice")
        XCTAssertEqual(ArchiveDayFile.body(of: ["type": "sticker", "emoji": "😀"], messageId: 7100),
                       "[sticker](media/7100/) 😀")
    }

    // Scenario "Poll question that looks like a block header".
    func testAPollQuestionLineShapedLikeAHeaderIsEscaped() {
        let body = ArchiveDayFile.body(of: ["type": "poll", "question": "Who?\n**09:00 Manager**：", "options": ["A"]],
                                       messageId: 7200)
        let out = ArchiveDayFile.render(chatId: 777, day: "2026-10-11", utcOffset: "+08:00",
                                        messages: [ArchiveMessage(id: 7200, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: body)])
        XCTAssertTrue(out.contains("<!-- msg:7200 -->\n**09:00 Alex**：\n[poll] Who?\n\\**09:00 Manager**：\n- A\n\n"), out)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(out).map(\.id), [7200])
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
        let (content, added, _) = ArchiveDayFile.merged(existing: first, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                                     messages: [message(40, minute: 1), message(50, minute: 2)])
        XCTAssertEqual(added, [40])
        XCTAssertEqual(ArchiveDayFile.parseBlocks(content).map(\.id), [30, 40, 50])
        XCTAssertEqual(content.components(separatedBy: "<!-- msg:50 -->").count - 1, 1)
    }

    func testExistingBlocksKeepTheirExactText() {
        let existing = "---\nchat_id: 7\ndate: 2026-10-11\nutc_offset: \"+08:00\"\n---\n\n"
            + "<!-- msg:50 -->\n**09:02 Old name**：\nedited by hand\n\n"
        let (content, _, _) = ArchiveDayFile.merged(existing: existing, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                                 messages: [message(50, minute: 2, sender: "New name"), message(60, minute: 3)])
        XCTAssertTrue(content.contains("<!-- msg:50 -->\n**09:02 Old name**：\nedited by hand\n\n"), content)
        XCTAssertFalse(content.contains("New name"), content)
        XCTAssertTrue(content.hasSuffix("<!-- msg:60 -->\n**09:03 Alex**：\nm60\n\n"), content)
    }

    // Scenario "Re-run without new messages".
    func testRerunWithoutNewMessagesLeavesTheFileByteIdentical() throws {
        let dir = try tempDir()
        let batch = [message(30, minute: 0), message(40, minute: 1)]
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: batch).added, [30, 40])
        let file = dir.appendingPathComponent("2026-10-11.md")
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: batch).added, [])
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

    // MARK: - Regular files only (#76)

    private let validHead = "---\nchat_id: 1\ndate: 2026-10-11\nutc_offset: \"+08:00\"\n---\n\n"

    private final class Thrown: @unchecked Sendable { var error: Error? }

    /// The error `body` throws, failing the test when it has not returned within 5 seconds. A
    /// reader stuck opening the FIFO `fifo` is then released by opening its write end, so the
    /// test run does not hang on the code before the fix.
    private func errorWithoutBlocking(releasing fifo: URL, _ body: @escaping @Sendable () throws -> Void,
                                      file: StaticString = #filePath, line: UInt = #line) -> Error? {
        let done = DispatchSemaphore(value: 0)
        let thrown = Thrown()
        DispatchQueue.global().async {
            do { try body() } catch { thrown.error = error }
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = done.wait(timeout: .now() + 5)
            XCTFail("blocked opening a FIFO named like a day file", file: file, line: line)
        }
        return thrown.error
    }

    private func fileType(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : 0
    }

    // Scenario "FIFO named like a day file".
    func testFIFODayFileIsRefusedWithoutBlocking() throws {
        let dir = try scratchDir()
        let fifo = dir.appendingPathComponent("2026-10-11.md")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let precheck = errorWithoutBlocking(releasing: fifo) {
            try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00")
        }
        XCTAssertEqual(precheck as? ArchiveDayFile.WriteError, .notRegularFile(day: "2026-10-11"))
        let m = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
        let write = errorWithoutBlocking(releasing: fifo) {
            try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        }
        XCTAssertEqual(write as? ArchiveDayFile.WriteError, .notRegularFile(day: "2026-10-11"))
        XCTAssertEqual(fileType(fifo), S_IFIFO)
    }

    // Scenario "Day file that is a symbolic link".
    func testSymlinkedDayFileIsRefusedAndNothingChanges() throws {
        let dir = try scratchDir()
        let outside = try scratchDir().appendingPathComponent("elsewhere.md")
        try Data((validHead + "<!-- msg:5 -->\n**09:00 Alex**：\na\n\n").utf8).write(to: outside)
        let before = try Data(contentsOf: outside)
        let link = dir.appendingPathComponent("2026-10-11.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00")) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .notRegularFile(day: "2026-10-11"))
            XCTAssertTrue(error.localizedDescription.contains("not a regular file"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("cannot be merged into safely"), error.localizedDescription)
        }
        let m = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
        XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                      messages: [m])) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .notRegularFile(day: "2026-10-11"))
        }
        XCTAssertEqual(fileType(link), S_IFLNK)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["2026-10-11.md"], "no temporary left")
    }

    /// A dangling link and a directory named like a day file are refused too, before and at the merge.
    func testDanglingSymlinkAndDirectoryAreRefused() throws {
        let dir = try scratchDir()
        let missing = dir.appendingPathComponent("missing.md")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("2026-10-11.md"), withDestinationURL: missing)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("2026-10-12.md"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00")) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .notRegularFile(day: "2026-10-11"))
        }
        for day in ["2026-10-11", "2026-10-12"] {
            let m = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
            XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: day, utcOffset: "+08:00",
                                                          messages: [m])) { error in
                XCTAssertEqual(error as? ArchiveDayFile.WriteError, .notRegularFile(day: day))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "the link's target is not created")
        XCTAssertEqual(fileType(dir.appendingPathComponent("2026-10-12.md")), S_IFDIR)
    }

    /// A loop of links above the day file is a path that cannot be read, not a day file that is a
    /// link; a socket named like a day file is not a regular file (#76 verify round 1).
    func testParentLinkLoopIsUnreadableAndASocketIsNotARegularFile() throws {
        let dir = try scratchDir()
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertThrowsError(try ArchiveDayFile.readDayFile(a.appendingPathComponent("2026-10-11.md"), day: "2026-10-11")) {
            XCTAssertEqual($0 as? ArchiveDayFile.WriteError, .unreadableOffset(day: "2026-10-11"))
        }
        // A socket path must fit sockaddr_un (104 bytes), so this one lives under /tmp.
        let short = URL(fileURLWithPath: "/tmp").appendingPathComponent("df-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: short) }
        let path = short.appendingPathComponent("2026-10-11.md").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(fileType(URL(fileURLWithPath: path)), S_IFSOCK)
        XCTAssertThrowsError(try ArchiveDayFile.checkOffsets(directory: short, utcOffset: "+08:00")) {
            XCTAssertEqual($0 as? ArchiveDayFile.WriteError, .notRegularFile(day: "2026-10-11"))
        }
    }

    // MARK: - Carriage returns (#76)

    // Scenario "Carriage return below the frontmatter": "\r\n" is one Character, so the merge would
    // find no anchor in a CRLF body and add every message again.
    func testDayFileWithACarriageReturnIsRefusedAtTheMerge() throws {
        let bodies = ["<!-- msg:5 -->\r\n**09:00 Alex**：\r\na\r\n\r\n",     // CRLF below LF frontmatter
                      "<!-- msg:5 -->\n**09:00 Alex**：\na\rb\n\n"]           // a lone CR
        for body in bodies {
            let dir = try scratchDir()
            let file = dir.appendingPathComponent("2026-10-11.md")
            try Data((validHead + body).utf8).write(to: file)
            let before = try Data(contentsOf: file)
            XCTAssertNoThrow(try ArchiveDayFile.checkOffsets(directory: dir, utcOffset: "+08:00"),
                             "the check before reading looks at the frontmatter only")
            let m = ArchiveMessage(id: 11, date: utc(2026, 10, 11, 2, 0), sender: "Alex", body: "b")
            XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                          messages: [m])) { error in
                XCTAssertEqual(error as? ArchiveDayFile.WriteError, .carriageReturn(day: "2026-10-11"))
            }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    /// A day file with a carriage return and a provisional block of the call's message would be
    /// rewritten by a TDLib run's upgrade, so that run is refused like one that adds a message; a
    /// cache run would change nothing and leaves it as it is (#72, #76).
    func testCarriageReturnFileIsRefusedWhenAProvisionalBlockWouldBeUpgraded() throws {
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("2026-10-11.md")
        let text = validHead + "<!-- msg:5 -->\r\n<!-- provisional: local-cache -->\r\n**09:00 User 1001**：\r\na\r\n\r\n"
            + "<!-- msg:6 -->\n**09:01 Alex**：\nb\n\n"
        try Data(text.utf8).write(to: file)
        let before = try Data(contentsOf: file)
        let five = ArchiveMessage(id: 5, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: "a")
        let six = ArchiveMessage(id: 6, date: utc(2026, 10, 11, 1, 1), sender: "Alex", body: "b")
        let fromCache = try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                 messages: [five, six], provisional: true)
        XCTAssertEqual(fromCache.added + fromCache.upgraded, [])
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                messages: [six]).added, [], "no provisional block of the call's messages")
        XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                      messages: [five, six])) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .carriageReturn(day: "2026-10-11"))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        // The same file with LF line ends is upgraded.
        try Data(text.replacingOccurrences(of: "\r\n", with: "\n").utf8).write(to: file)
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                messages: [five, six]).upgraded, [5])
    }

    /// A day file with a carriage return that already holds every message of the call is left as it
    /// is, so a first archive or a since_date re-run does not stop on an old CRLF file. Anchors are
    /// read with CRLF as a line end only: a lone CR cannot make text look like an anchor.
    func testDayFileWithACarriageReturnIsLeftAloneWhenNothingIsAdded() throws {
        let dir = try scratchDir()
        let file = dir.appendingPathComponent("2026-10-11.md")
        let text = validHead + "<!-- msg:5 -->\r\n**09:00 Alex**：\r\na\r\n\r\n"
            + "<!-- msg:6 -->\n**09:01 Alex**：\nb\r<!-- msg:9 -->\n\n"
        try Data(text.utf8).write(to: file)
        let before = try Data(contentsOf: file)
        func message(_ id: Int64) -> ArchiveMessage {
            ArchiveMessage(id: id, date: utc(2026, 10, 11, 1, 0), sender: "Alex", body: "x")
        }
        XCTAssertEqual(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                messages: [message(5), message(6)]).added, [])
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try ArchiveDayFile.write(directory: dir, chatId: 1, day: "2026-10-11", utcOffset: "+08:00",
                                                      messages: [message(6), message(9)])) { error in
            XCTAssertEqual(error as? ArchiveDayFile.WriteError, .carriageReturn(day: "2026-10-11"))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// The refusal cannot hit a file the tool wrote: its output never contains a carriage return.
    func testRenderedDayFilesHaveNoCarriageReturn() {
        let m = ArchiveMessage(id: 10, date: utc(2026, 10, 11, 1, 0), sender: "A\r\nB\rC", body: "x\r\ny\rz\r")
        let out = ArchiveDayFile.render(chatId: 1, day: "2026-10-11", utcOffset: "+08:00", messages: [m])
        XCTAssertFalse(out.unicodeScalars.contains("\r"), out)
    }

    /// Every day-file refusal carries the phrase the archive-telegram skill matches on.
    func testDayFileRefusalsShareOnePhrase() {
        let errors: [ArchiveDayFile.WriteError] = [.unreadableOffset(day: "2026-10-11"), .notRegularFile(day: "2026-10-11"),
                                                   .carriageReturn(day: "2026-10-11")]
        for error in errors {
            XCTAssertTrue(error.localizedDescription.contains("cannot be merged into safely"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("2026-10-11.md"), error.localizedDescription)
        }
    }

    // MARK: - Provisional blocks written from the local cache (#72)

    private let marker = "<!-- provisional: local-cache -->"
    private let head = "---\nchat_id: 7\ndate: 2026-10-11\nutc_offset: \"+08:00\"\n---\n\n"

    // Example "block written from the local cache": the marker is the line after the anchor.
    func testACacheBlockHasTheMarkerAsItsSecondLine() {
        XCTAssertEqual(ArchiveDayFile.provisionalMarker, marker)
        let m = ArchiveMessage(id: 30, date: utc(2026, 10, 11, 0, 3), sender: "User 1001", body: "hi")
        XCTAssertEqual(ArchiveDayFile.block(m, offsetSeconds: 28_800, provisional: true),
                       "<!-- msg:30 -->\n<!-- provisional: local-cache -->\n**08:03 User 1001**：\nhi\n\n")
        XCTAssertEqual(ArchiveDayFile.block(m, offsetSeconds: 28_800), "<!-- msg:30 -->\n**08:03 User 1001**：\nhi\n\n")
    }

    /// Anchors are unchanged, so a parser that knows nothing of the marker (v0.8.0's) finds the same blocks.
    func testMarkersDoNotChangeWhereBlocksStart() {
        let messages = [message(30, minute: 0), message(50, minute: 2)]
        let marked = ArchiveDayFile.merged(existing: nil, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                           messages: messages, provisional: true).content
        XCTAssertEqual(marked.components(separatedBy: "\n\(marker)\n").count - 1, 2, marked)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(marked).map(\.id), [30, 50])
        XCTAssertEqual(ArchiveDayFile.parseBlocks(marked).map { ArchiveDayFile.isProvisional($0.text) }, [true, true])
    }

    // Example "which existing blocks a call replaces": a TDLib merge replaces marked blocks only.
    func testATDLibMergeUpgradesProvisionalBlocksOnly() {
        let block30 = "<!-- msg:30 -->\n\(marker)\n**09:00 User 1001**：\n[photo](media/30/)\n\n"
        let block40 = "<!-- msg:40 -->\n**09:01 Old name**：\nedited by hand\n\n"
        let block50 = "<!-- msg:50 -->\n\(marker)\n**09:02 User 1001**：\nm50\n\n"
        let existing = head + "a note before the first block\n\n" + block30 + block40 + block50
        let (content, added, upgraded) = ArchiveDayFile.merged(
            existing: existing, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
            messages: [message(30, minute: 0, body: "[photo](media/30/) menu"),
                       message(40, minute: 1, sender: "New name"), message(60, minute: 3)])
        XCTAssertEqual(upgraded, [30])
        XCTAssertEqual(added, [60])
        XCTAssertEqual(content, head + "a note before the first block\n\n"
            + "<!-- msg:30 -->\n**09:00 Alex**：\n[photo](media/30/) menu\n\n"
            + block40 + block50 + "<!-- msg:60 -->\n**09:03 Alex**：\nm60\n\n")
    }

    func testACacheMergeReplacesNothing() {
        let block30 = "<!-- msg:30 -->\n\(marker)\n**09:00 User 1001**：\nm30\n\n"
        let block40 = "<!-- msg:40 -->\n**09:01 Alex**：\nm40\n\n"
        let (content, added, upgraded) = ArchiveDayFile.merged(
            existing: head + block30 + block40, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
            messages: [message(30, minute: 0, sender: "User 1001", body: "different"),
                       message(40, minute: 1, sender: "User 1001"), message(60, minute: 3, sender: "User 1001")],
            provisional: true)
        XCTAssertEqual(upgraded, [])
        XCTAssertEqual(added, [60])
        XCTAssertEqual(content, head + block30 + block40 + "<!-- msg:60 -->\n\(marker)\n**09:03 User 1001**：\nm60\n\n")
    }

    // Scenario "Text that looks like the marker".
    func testABodyLineThatIsTheMarkerCannotMakeABlockProvisional() {
        let file = ArchiveDayFile.render(chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                         messages: [message(40, minute: 0, body: marker + "\nok")])
        XCTAssertTrue(file.contains("**09:00 Alex**：\n\\\(marker)\nok\n"), file)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(file).map { ArchiveDayFile.isProvisional($0.text) }, [false])
        let (content, _, upgraded) = ArchiveDayFile.merged(existing: file, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                                           messages: [message(40, minute: 0, sender: "Other")])
        XCTAssertEqual(upgraded, [])
        XCTAssertEqual(content, file)
    }

    /// Only the second line marks a block; the marker anywhere else is just text the tool did not write.
    func testTheMarkerCountsOnlyAsTheSecondLine() {
        XCTAssertTrue(ArchiveDayFile.isProvisional("<!-- msg:1 -->\n\(marker)\n**09:00 A**：\nx\n\n"))
        XCTAssertTrue(ArchiveDayFile.isProvisional("<!-- msg:1 -->\n\(marker)"), "a hand-cut block at the end of a file")
        XCTAssertFalse(ArchiveDayFile.isProvisional("<!-- msg:1 -->\n**09:00 A**：\n\(marker)\n\n"))
        XCTAssertFalse(ArchiveDayFile.isProvisional("<!-- msg:1 -->\n \(marker)\n**09:00 A**：\n\n"))
        XCTAssertFalse(ArchiveDayFile.isProvisional("<!-- msg:1 -->\n<!-- provisional: local-cache -->x\n\n"))
    }

    // Scenario "TDLib re-run after an upgrade", at the file level.
    func testWriteUpgradesOnceThenLeavesTheFileByteIdentical() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("2026-10-11.md")
        let cached = [message(30, minute: 0, sender: "User 1001"), message(40, minute: 1, sender: "User 1001")]
        let first = try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                             messages: cached, provisional: true)
        XCTAssertEqual(first.added, [30, 40])
        let afterCache = try Data(contentsOf: file)
        let cacheAgain = try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00",
                                                  messages: cached, provisional: true)
        XCTAssertEqual(cacheAgain.added + cacheAgain.upgraded, [])
        XCTAssertEqual(try Data(contentsOf: file), afterCache, "a cache run over cache blocks changes nothing")

        let full = [message(30, minute: 0), message(40, minute: 1)]
        let upgrade = try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: full)
        XCTAssertEqual(upgrade.added, [])
        XCTAssertEqual(upgrade.upgraded, [30, 40])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       ArchiveDayFile.render(chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: full))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["2026-10-11.md"], "no temporary file left")

        let afterUpgrade = try Data(contentsOf: file)
        let again = try ArchiveDayFile.write(directory: dir, chatId: 7, day: "2026-10-11", utcOffset: "+08:00", messages: full)
        XCTAssertEqual(again.added + again.upgraded, [])
        XCTAssertEqual(try Data(contentsOf: file), afterUpgrade)
    }
}
