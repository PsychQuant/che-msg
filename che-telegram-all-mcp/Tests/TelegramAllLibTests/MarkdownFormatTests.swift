import XCTest
@testable import TelegramAllLib

/// Verifies Markdown output format contract.
///
/// Covers spec requirement: "Markdown output format"
final class MarkdownFormatTests: XCTestCase {

    private func msg(
        id: Int64,
        date: Foundation.Date,
        senderId: Int64,
        isOutgoing: Bool,
        type: String = "text",
        text: String = ""
    ) -> [String: Any] {
        [
            "id": id,
            "date": Int(date.timeIntervalSince1970),
            "sender": ["type": "user", "user_id": senderId],
            "is_outgoing": isOutgoing,
            "type": type,
            "text": text,
        ]
    }

    /// Anchor the test date to a fixed point — independent of the run machine's current time.
    private let anchor = Foundation.Date(timeIntervalSince1970: 1_744_675_920)  // 2025-04-15 01:32:00 UTC

    // MARK: - Level 1 heading

    func testLevel1HeadingIncludesChatTitleAndId() {
        let md = formatMarkdown(
            messages: [],
            senderNames: [:],
            selfLabel: "我",
            chatTitle: "小明 王",
            chatId: 123456789,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: anchor
        )
        XCTAssertTrue(md.hasPrefix("# 對話：小明 王 (chat_id=123456789)\n"),
                      "Level 1 heading MUST include chat title and numeric chat_id")
    }

    // MARK: - Metadata line

    func testMetadataLineIncludesCountAndDateRange() {
        let calendar = Calendar(identifier: .gregorian)
        let since = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let until = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))!
        let md = formatMarkdown(
            messages: [
                msg(id: 1, date: anchor, senderId: 10, isOutgoing: false, text: "hi"),
            ],
            senderNames: [10: "Alice"],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: since,
            untilDate: until,
            exportedAt: anchor
        )
        XCTAssertTrue(md.contains("訊息數：1"), "Metadata MUST include message count")
        XCTAssertTrue(md.contains("since 2026-03-01"), "Metadata MUST include sinceDate")
        XCTAssertTrue(md.contains("until 2026-04-15"), "Metadata MUST include untilDate")
    }

    // MARK: - Day headings chronological

    func testDayHeadingsAppearChronologically() {
        let calendar = Calendar(identifier: .gregorian)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 12, hour: 14, minute: 0))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 13, hour: 10, minute: 0))!
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 9, minute: 30))!

        // Newest-first order (TDLib convention).
        let messages = [
            msg(id: 3, date: day3, senderId: 1, isOutgoing: false, text: "c"),
            msg(id: 2, date: day2, senderId: 1, isOutgoing: false, text: "b"),
            msg(id: 1, date: day1, senderId: 1, isOutgoing: false, text: "a"),
        ]
        let md = formatMarkdown(
            messages: messages,
            senderNames: [1: "Alice"],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: anchor
        )
        let r12 = md.range(of: "## 2026-04-12")
        let r13 = md.range(of: "## 2026-04-13")
        let r14 = md.range(of: "## 2026-04-14")
        XCTAssertNotNil(r12)
        XCTAssertNotNil(r13)
        XCTAssertNotNil(r14)
        if let a = r12?.lowerBound, let b = r13?.lowerBound, let c = r14?.lowerBound {
            XCTAssertTrue(a < b && b < c,
                          "Day headings MUST appear in chronological order regardless of input order")
        }
    }

    // MARK: - HH:mm sender line format

    func testOutgoingMessageUsesSelfLabel() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 32))!
        let md = formatMarkdown(
            messages: [msg(id: 1, date: at, senderId: 99, isOutgoing: true, text: "會議幾點開始？")],
            senderNames: [:],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: anchor
        )
        XCTAssertTrue(md.contains("**14:32 我**：\n會議幾點開始？"),
                      "Outgoing message MUST format as **HH:mm <self_label>**：\\n<text>")
    }

    func testIncomingMessageUsesResolvedSenderName() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 33))!
        let md = formatMarkdown(
            messages: [msg(id: 2, date: at, senderId: 42, isOutgoing: false, text: "下午兩點")],
            senderNames: [42: "小明"],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: anchor
        )
        XCTAssertTrue(md.contains("**14:33 小明**：\n下午兩點"),
                      "Incoming message MUST use resolved sender name")
    }

    // MARK: - Media placeholders

    func testMediaTypePlaceholders() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 34))!
        let mediaCases: [(String, String)] = [
            ("photo", "[photo]"),
            ("video", "[video]"),
            ("voice_note", "[voice]"),
            ("sticker", "[sticker]"),
            ("document", "[document]"),
            ("location", "[location]"),
            ("animation", "[animation]"),
            ("video_note", "[video_note]"),
            ("poll", "[poll]"),
            ("audio", "[audio]"),
            ("unknown_type", "[other]"),
        ]
        for (type, expectedPlaceholder) in mediaCases {
            let md = formatMarkdown(
                messages: [msg(id: 1, date: at, senderId: 1, isOutgoing: false, type: type)],
                senderNames: [1: "X"],
                selfLabel: "我",
                chatTitle: "T",
                chatId: 1,
                sinceDate: nil,
                untilDate: nil,
                exportedAt: anchor
            )
            XCTAssertTrue(md.contains(expectedPlaceholder),
                          "Message type \(type) MUST render as \(expectedPlaceholder)")
        }
    }

    // MARK: - Media captions (#70)

    private func media(_ type: String, caption: String?) -> [String: Any] {
        var m: [String: Any] = ["id": Int64(1), "type": type, "text": ""]
        if let caption { m["caption"] = caption }
        return m
    }

    func testACaptionFollowsThePlaceholder() {
        XCTAssertEqual(messageBody(media("photo", caption: "menu")), "[photo] menu")
    }

    func testAMediaMessageWithoutACaptionIsUnchanged() {
        XCTAssertEqual(messageBody(media("photo", caption: "")), "[photo]", "TDLib writes an empty caption when there is none")
        XCTAssertEqual(messageBody(media("photo", caption: nil)), "[photo]")
    }

    func testAMultiLineCaptionKeepsItsLineBreaks() {
        XCTAssertEqual(messageBody(media("video", caption: "line one\nline two")), "[video] line one\nline two")
    }

    func testEveryCaptionedTypeKeepsItsCaption() {
        let cases: [(String, String)] = [
            ("photo", "[photo]"), ("video", "[video]"), ("voice_note", "[voice]"),
            ("document", "[document]"), ("animation", "[animation]"), ("audio", "[audio]"),
        ]
        for (type, placeholder) in cases {
            XCTAssertEqual(messageBody(media(type, caption: "c")), "\(placeholder) c", type)
            XCTAssertEqual(messageBody(media(type, caption: "")), placeholder, type)
        }
    }

    func testACaptionInTheExportSitsUnderTheHeader() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 34))!
        var m = msg(id: 1, date: at, senderId: 1, isOutgoing: false, type: "photo")
        m["caption"] = "menu"
        let md = formatMarkdown(messages: [m], senderNames: [1: "X"], selfLabel: "我", chatTitle: "T", chatId: 1,
                                sinceDate: nil, untilDate: nil, exportedAt: anchor)
        XCTAssertTrue(md.contains("X**：\n[photo] menu\n"), md)
    }

    // MARK: - Poll, sticker and location details (#82)

    // Scenario "Poll with its options".
    func testAPollKeepsItsQuestionAndOptions() {
        let poll: [String: Any] = ["id": Int64(1), "type": "poll", "question": "Lunch?", "options": ["Noodles", "Rice"]]
        XCTAssertEqual(messageBody(poll), "[poll] Lunch?\n- Noodles\n- Rice")
    }

    // Scenario "Sticker and location details".
    func testAStickerKeepsItsEmojiAndALocationItsCoordinates() {
        XCTAssertEqual(messageBody(["id": Int64(1), "type": "sticker", "emoji": "😀"]), "[sticker] 😀")
        XCTAssertEqual(messageBody(["id": Int64(1), "type": "location", "latitude": 25.0478, "longitude": 121.5319]),
                       "[location] 25.0478,121.5319")
    }

    // Scenario "Coordinate near zero".
    func testACoordinateNearZeroHasNoExponent() {
        XCTAssertEqual(messageBody(["id": Int64(1), "type": "location", "latitude": 0.00001, "longitude": -0.5]),
                       "[location] 0.00001,-0.5")
    }

    // Scenario "Poll from the local cache": the reader gives the type and nothing else.
    func testAPollWithoutDetailsIsTheBarePlaceholder() {
        XCTAssertEqual(messageBody(["id": Int64(1), "type": "poll"]), "[poll]")
        XCTAssertEqual(messageBody(["id": Int64(1), "type": "sticker"]), "[sticker]")
        XCTAssertEqual(messageBody(["id": Int64(1), "type": "location"]), "[location]")
    }

    func testPollOptionsSitUnderTheHeaderInTheExport() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 34))!
        var m = msg(id: 1, date: at, senderId: 1, isOutgoing: false, type: "poll")
        m["question"] = "Lunch?"
        m["options"] = ["Noodles", "Rice"]
        let md = formatMarkdown(messages: [m], senderNames: [1: "X"], selfLabel: "我", chatTitle: "T", chatId: 1,
                                sinceDate: nil, untilDate: nil, exportedAt: anchor)
        XCTAssertTrue(md.contains("X**：\n[poll] Lunch?\n- Noodles\n- Rice\n\n"), md)
    }

    // MARK: - Consecutive same-sender messages NOT merged

    func testConsecutiveSameSenderRetainIndependentTimestamps() {
        let calendar = Calendar(identifier: .gregorian)
        let t1 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 33))!
        let t2 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 14, minute: 35))!
        let md = formatMarkdown(
            messages: [
                msg(id: 2, date: t2, senderId: 42, isOutgoing: false, text: "下午兩點"),
                msg(id: 1, date: t1, senderId: 42, isOutgoing: false, type: "photo"),
            ],
            senderNames: [42: "小明"],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: anchor
        )
        // Two distinct 14:3X timestamps MUST both appear.
        XCTAssertTrue(md.contains("**14:33 小明**"),
                      "First message timestamp MUST be preserved")
        XCTAssertTrue(md.contains("**14:35 小明**"),
                      "Second message timestamp MUST be preserved (no merging)")
    }

    // MARK: - Gregorian, ASCII digits whatever the Region (#84)

    /// The only guard that works on a Gregorian host: a formatter that took
    /// the Region's calendar or digits would print era years or native digits
    /// under another Region, and sort day sections wrongly.
    func testTheDateFormattersAreGregorianWithASCIIDigits() {
        for formatter in [DateFormatter.isoDay, DateFormatter.hourMinute, DateFormatter.exportTimestamp] {
            XCTAssertEqual(formatter.calendar.identifier, .gregorian, formatter.dateFormat)
            XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX", formatter.dateFormat)
        }
    }
}

