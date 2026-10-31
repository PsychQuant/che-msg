import XCTest
@testable import TelegramAllLib

/// PsychQuant/che-msg#101: tool results are compact JSON — no line breaks,
/// indentation or spaces around colons — with keys and values unchanged.
final class JSONOutputTests: XCTestCase {
    /// Keys deliberately out of order; no `/` (JSONSerialization escapes it).
    let value: [String: Any] = [
        "text": "收到\n第二行",
        "b": [1, 2],
        "a": ["x": "y z"],
    ]
    /// Written by hand: sorted keys, no layout whitespace, the newline inside
    /// the string escaped, CJK left as is.
    let expected = #"{"a":{"x":"y z"},"b":[1,2],"text":"收到\n第二行"}"#

    func testJSONOutputIsCompactWithSortedKeys() {
        XCTAssertEqual(JSONOutput.string(value), expected)
    }

    func testLocalReaderJSONIsCompactWithSortedKeys() {
        XCTAssertEqual(LocalTDLibReader.json(value), expected)
    }
}
