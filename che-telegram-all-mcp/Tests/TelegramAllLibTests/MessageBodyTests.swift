import XCTest
@testable import TelegramAllLib

/// The message body both Markdown writers share (telegram-history-export "Markdown output
/// format", telegram-chat-archive "Day file format"; PsychQuant/che-msg#82). Synthetic values only.
final class MessageBodyTests: XCTestCase {
    private func poll(_ question: String?, _ options: Any?) -> [String: Any] {
        var m: [String: Any] = ["type": "poll"]
        if let question { m["question"] = question }
        if let options { m["options"] = options }
        return m
    }

    // Scenario "Poll with its options".
    func testPollWritesItsQuestionThenOneLinePerOption() {
        XCTAssertEqual(MessageBody.render(poll("Lunch?", ["Noodles", "Rice"]), placeholder: "[poll]"),
                       "[poll] Lunch?\n- Noodles\n- Rice")
    }

    func testPollWithoutOptionsWritesItsQuestion() {
        XCTAssertEqual(MessageBody.render(poll("Lunch?", nil), placeholder: "[poll]"), "[poll] Lunch?")
        XCTAssertEqual(MessageBody.render(poll("Lunch?", [String]()), placeholder: "[poll]"), "[poll] Lunch?")
    }

    func testPollWithoutAQuestionStillListsItsOptions() {
        XCTAssertEqual(MessageBody.render(poll("", ["A", "B"]), placeholder: "[poll]"), "[poll]\n- A\n- B")
        XCTAssertEqual(MessageBody.render(poll(nil, ["A"]), placeholder: "[poll]"), "[poll]\n- A")
    }

    func testEmptyOptionsAreSkippedAndLineBreaksInAnOptionBecomeSpaces() {
        XCTAssertEqual(MessageBody.render(poll("Q", ["", "one\ntwo", "three\r\nfour"]), placeholder: "[poll]"),
                       "[poll] Q\n- one two\n- three four")
    }

    func testLineBreaksInAPollQuestionAreKept() {
        XCTAssertEqual(MessageBody.render(poll("first\nsecond", ["A"]), placeholder: "[poll]"),
                       "[poll] first\nsecond\n- A")
    }

    func testOptionsThatAreNotStringsAreIgnored() {
        XCTAssertEqual(MessageBody.render(poll("Q", [1, 2]), placeholder: "[poll]"), "[poll] Q")
        XCTAssertEqual(MessageBody.render(poll("Q", "A"), placeholder: "[poll]"), "[poll] Q")
    }

    func testStickerWritesItsEmoji() {
        XCTAssertEqual(MessageBody.render(["type": "sticker", "emoji": "😀"], placeholder: "[sticker]"), "[sticker] 😀")
        XCTAssertEqual(MessageBody.render(["type": "sticker", "emoji": ""], placeholder: "[sticker]"), "[sticker]")
        XCTAssertEqual(MessageBody.render(["type": "sticker"], placeholder: "[sticker]"), "[sticker]")
    }

    // Scenario "Sticker and location details": numbers as JSONSerialization and messageToDict give them.
    func testLocationWritesItsCoordinates() {
        let fromJSON = ["type": "location", "latitude": NSNumber(value: 25.0478), "longitude": NSNumber(value: 121.5319)] as [String: Any]
        XCTAssertEqual(MessageBody.render(fromJSON, placeholder: "[location]"), "[location] 25.0478,121.5319")
        let fromTDLib: [String: Any] = ["type": "location", "latitude": -33.8688, "longitude": 151.2093]
        XCTAssertEqual(MessageBody.render(fromTDLib, placeholder: "[location]"), "[location] -33.8688,151.2093")
    }

    // Scenario "Coordinate near zero": no exponent.
    func testACoordinateNearZeroIsWrittenWithoutAnExponent() {
        let m: [String: Any] = ["type": "location", "latitude": 0.00001, "longitude": -0.5]
        XCTAssertEqual(MessageBody.render(m, placeholder: "[location]"), "[location] 0.00001,-0.5")
    }

    func testCoordinatesAreNotRounded() {
        let m: [String: Any] = ["type": "location", "latitude": 25.047812345678901, "longitude": 121.53191234567891]
        let body = MessageBody.render(m, placeholder: "[location]")
        let parts = body.dropFirst("[location] ".count).split(separator: ",").map { Double(String($0)) }
        XCTAssertEqual(parts, [25.047812345678901, 121.53191234567891], body)
    }

    func testALocationWithoutBothCoordinatesHasNoDetail() {
        XCTAssertEqual(MessageBody.render(["type": "location", "latitude": 25.0], placeholder: "[location]"), "[location]")
        XCTAssertEqual(MessageBody.render(["type": "location", "latitude": "25", "longitude": "121"], placeholder: "[location]"),
                       "[location]")
        XCTAssertEqual(MessageBody.render(["type": "location", "latitude": Double.nan, "longitude": 1.0], placeholder: "[location]"),
                       "[location]")
        XCTAssertEqual(MessageBody.render(["type": "location"], placeholder: "[location]"), "[location]")
    }

    func testPlainDecimal() {
        XCTAssertEqual(MessageBody.plainDecimal(1e-05), "0.00001")
        XCTAssertEqual(MessageBody.plainDecimal(1.5e-07), "0.00000015")
        XCTAssertEqual(MessageBody.plainDecimal(-2.25e-06), "-0.00000225")
        XCTAssertEqual(MessageBody.plainDecimal(25.0), "25.0")
        XCTAssertEqual(MessageBody.plainDecimal(-0.5), "-0.5")
        XCTAssertEqual(MessageBody.plainDecimal(121.5319), "121.5319")
        XCTAssertEqual(MessageBody.plainDecimal(1e16), "10000000000000000.0")
        XCTAssertEqual(MessageBody.plainDecimal(1.25e17), "125000000000000000.0")
        for value in [1e-05, 1.5e-07, 0.0001234, 179.99999999999997, -89.123456789] {
            XCTAssertEqual(Double(MessageBody.plainDecimal(value)), value, "\(value)")
        }
    }

    // Captions and text are written as before (#70).
    func testTextAndCaptionsAreUnchanged() {
        XCTAssertEqual(MessageBody.render(["type": "text", "text": "hello"], placeholder: "unused"), "hello")
        XCTAssertEqual(MessageBody.render(["type": "text"], placeholder: "unused"), "")
        XCTAssertEqual(MessageBody.render(["type": "photo", "caption": "menu"], placeholder: "[photo]"), "[photo] menu")
        XCTAssertEqual(MessageBody.render(["type": "photo", "caption": ""], placeholder: "[photo]"), "[photo]")
        XCTAssertEqual(MessageBody.render(["type": "video", "caption": "a\nb"], placeholder: "[video]"), "[video] a\nb")
    }

    func testOtherTypesAndMessagesWithoutDetailsGetTheirLabelAlone() {
        XCTAssertEqual(MessageBody.render(["type": "other"], placeholder: "[other]"), "[other]")
        XCTAssertEqual(MessageBody.render(["type": "video_note"], placeholder: "[video_note]"), "[video_note]")
        // As the local cache gives a poll: a type and nothing else.
        XCTAssertEqual(MessageBody.render(["type": "poll"], placeholder: "[poll]"), "[poll]")
    }

    /// A detail belongs to its type only: a poll's question is not read from a photo.
    func testDetailsAreReadByType() {
        XCTAssertEqual(MessageBody.render(["type": "photo", "question": "Q", "emoji": "😀"], placeholder: "[photo]"), "[photo]")
        XCTAssertEqual(MessageBody.render(["type": "poll", "caption": "c"], placeholder: "[poll]"), "[poll]")
    }

    /// A line break followed by a combining mark (or ZWJ, a variation selector, CGJ) still ends the
    /// line for a reader comparing code points, so inside an option it becomes a space as well (#82).
    func testALineBreakFollowedByAMarkInAnOptionBecomesASpace() {
        for mark in ["\u{301}", "\u{200D}", "\u{FE0F}", "\u{34F}"] {
            let body = MessageBody.render(poll("Q", ["one\n" + mark + "two", "three\r" + mark + "four"]), placeholder: "[poll]")
            XCTAssertEqual(body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).count, 3, body)
            XCTAssertFalse(body.unicodeScalars.contains("\r"))
        }
    }
}
