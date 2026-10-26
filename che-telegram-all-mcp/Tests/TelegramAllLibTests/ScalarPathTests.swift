import XCTest
@testable import TelegramAllLib

/// `ScalarPath` reads paths by Unicode scalar, as the OS does (#21): a "/"
/// followed by a combining mark is one Character but still a separator.
final class ScalarPathTests: XCTestCase {
    func testASlashBeforeACombiningMarkStillSeparates() {
        let path = "/tmp/..\u{2F}\u{301}x.md"
        XCTAssertEqual(path.split(separator: "/").count, 2, "Characters fuse the second '/' with the mark")
        XCTAssertEqual(ScalarPath.components(of: path), ["tmp", "..", "\u{301}x.md"])
        XCTAssertTrue(ScalarPath.components(of: path).contains(where: ScalarPath.isParent))
    }

    func testComponentsDropEmptiesAndKeepTheirScalars() {
        XCTAssertEqual(ScalarPath.components(of: "//a//b/"), ["a", "b"])
        XCTAssertEqual(ScalarPath.components(of: "/"), [])
        XCTAssertEqual(ScalarPath.components(of: "/cafe\u{301}").first?.unicodeScalars.count, 5)
    }

    func testAbsoluteIsTheFirstScalar() {
        XCTAssertTrue(ScalarPath.isAbsolute("/\u{301}x.md"))
        XCTAssertFalse(ScalarPath.isAbsolute("\u{301}/x.md"))
        XCTAssertFalse(ScalarPath.isAbsolute(""))
    }

    /// Swift's `==` treats NFC "é" and NFD "e" + U+0301 as equal; a path
    /// component is compared by its scalars.
    func testComponentsAreComparedScalarForScalar() {
        XCTAssertEqual("caf\u{E9}", "cafe\u{301}")
        XCTAssertFalse(ScalarPath.same("caf\u{E9}", "cafe\u{301}"))
        XCTAssertTrue(ScalarPath.isParent(".."))
        XCTAssertFalse(ScalarPath.isParent("..\u{301}"))
        XCTAssertFalse(ScalarPath.isParent("\u{301}.."))
        XCTAssertTrue(ScalarPath.isCurrent("."))
        XCTAssertFalse(ScalarPath.isCurrent(".\u{301}"))
    }
}
