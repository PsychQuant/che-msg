import XCTest
import TDLibKit
@testable import TelegramAllLib

/// Covers spec requirement: "Structured TDLib error propagation"
///                       and "TDLib error code 406 silent-ignore rule"
/// Corresponds to design Decisions 1, 2.
///
/// Tests target the file-scope helper `mapTDLibError(_:)` rather than instantiating
/// `TDLibClient`, because TDLib's receive loop is process-global and cannot tolerate
/// multiple instances in one test run (same constraint as `TDLibClientBackwardCompatTests`).
/// This keeps the tests deterministic and avoids any TDLib boot.
final class TDLibAuthErrorTests: XCTestCase {

    // MARK: - Structured TDLib error propagation

    func testFloodWaitErrorIsMappedWithStructuredCodeAndMessage() {
        let tdError = TDLibKit.Error(code: 420, message: "FLOOD_WAIT_30")

        XCTAssertThrowsError(try mapTDLibError(tdError)) { thrown in
            guard case .tdlibError(let code, let message) = thrown as? TelegramAllLib.TDLibClient.TDError else {
                XCTFail("Expected TDError.tdlibError, got \(thrown)")
                return
            }
            XCTAssertEqual(code, 420, "code MUST be propagated as Int")
            XCTAssertEqual(message, "FLOOD_WAIT_30", "message MUST be propagated as String")
        }
    }

    func testPhoneCodeInvalidIsMappedWithStructuredFields() {
        let tdError = TDLibKit.Error(code: 400, message: "PHONE_CODE_INVALID")

        XCTAssertThrowsError(try mapTDLibError(tdError)) { thrown in
            guard case .tdlibError(let code, let message) = thrown as? TelegramAllLib.TDLibClient.TDError else {
                XCTFail("Expected TDError.tdlibError, got \(thrown)")
                return
            }
            XCTAssertEqual(code, 400)
            XCTAssertEqual(message, "PHONE_CODE_INVALID")
        }
    }

    func testInternalServerErrorIsMappedWithStructuredFields() {
        let tdError = TDLibKit.Error(code: 500, message: "Internal")

        XCTAssertThrowsError(try mapTDLibError(tdError)) { thrown in
            guard case .tdlibError(let code, let message) = thrown as? TelegramAllLib.TDLibClient.TDError else {
                XCTFail("Expected TDError.tdlibError, got \(thrown)")
                return
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "Internal")
        }
    }

    // MARK: - Code 406 silent-ignore rule

    func testCode406ReturnsWithoutThrowing() throws {
        let tdError = TDLibKit.Error(code: 406, message: "Anything")

        // MUST NOT throw — TDLib protocol mandates silent-ignore for code 406.
        try mapTDLibError(tdError)
    }

    func testCode406WithEmptyMessageStillSilentlyIgnored() throws {
        let tdError = TDLibKit.Error(code: 406, message: "")

        try mapTDLibError(tdError)
    }

    func testCode400IsNotSilentlyIgnored() {
        let tdError = TDLibKit.Error(code: 400, message: "ANY")

        XCTAssertThrowsError(try mapTDLibError(tdError),
                             "Only code 406 may be silent-ignored; 400 MUST throw") { thrown in
            guard case .tdlibError(let code, _) = thrown as? TelegramAllLib.TDLibClient.TDError else {
                XCTFail("Expected TDError.tdlibError, got \(thrown)")
                return
            }
            XCTAssertEqual(code, 400)
        }
    }

    // MARK: - Non-TDLib errors pass through

    func testNonTDLibErrorIsRethrown() {
        struct CustomError: Swift.Error {}
        let other = CustomError()

        XCTAssertThrowsError(try mapTDLibError(other)) { thrown in
            XCTAssertTrue(thrown is CustomError,
                          "Non-TDLibKit errors MUST pass through unchanged")
        }
    }
}
