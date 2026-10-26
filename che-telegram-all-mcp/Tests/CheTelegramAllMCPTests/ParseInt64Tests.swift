import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `int64ArgValueStrict` (#22) and `requiredInt64` (#33), including the #33 verify follow-up on fractional doubles.
/// Moved out of ServerHandlerLogicTests.swift (#26) without changes.
final class ParseInt64Tests: XCTestCase {

    // MARK: - #22 verify F7: int64ArgValueStrict branch coverage

    /// Verify F7 — `.bool(true)` falls through to the no-quote branch
    /// (no meaningful string form). Docstring fixed to reflect this.
    func testInt64ArgValueStrictBoolThrowsGenericMessage() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .bool(true),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer")
        }
    }

    /// Verify F7 — explicit `.null` treated as absent (returns nil from
    /// `int64ArgValueStrict`, caller throws "X is required" via guard).
    func testInt64ArgValueStrictExplicitNullTreatsAsAbsent() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .null,
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
    }

    /// Verify F7 — fractional `.double(50.5)` rejected for limit (per
    /// `Int(_:strict:false)` semantics — `Int(exactly: 50.5)` is nil).
    func testLimitFractionalDoubleRejected() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .double(50.5),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "limit must be an integer")
        }
    }

    // MARK: - #33: requiredInt64 primitive (single-key Server.swift handlers)

    /// #33: junk string → type-mismatch message (was the misleading "is required"
    /// at the inline non-strict callsites). Mutation guard: revert the parser to
    /// non-strict int64ArgValue and this assertion fails (nil → "is required").
    func testRequiredInt64RejectsNonNumericString() {
        XCTAssertThrowsError(try requiredInt64(["chat_id": .string("abc")], "chat_id")) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"abc\"")
        }
    }

    /// #33: absent key → "X is required" (preserves the prior guard semantics).
    func testRequiredInt64ThrowsRequiredOnAbsent() {
        XCTAssertThrowsError(try requiredInt64([:], "chat_id")) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description, "chat_id is required")
        }
    }

    /// #33 SILENT WIDENING contract: whole-number .double ids (e.g. 12345.0 from
    /// JS/Python encoders) are now ACCEPTED at every Server.swift handler — the
    /// former non-strict int64ArgValue rejected these as nil → "is required".
    func testRequiredInt64AcceptsWholeNumberDouble() throws {
        XCTAssertEqual(try requiredInt64(["chat_id": .double(12345.0)], "chat_id"), 12345)
    }

    /// #33: .bool falls to the no-quote branch (no meaningful string form).
    func testRequiredInt64RejectsBool() {
        XCTAssertThrowsError(try requiredInt64(["chat_id": .bool(true)], "chat_id")) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description, "chat_id must be an integer")
        }
    }

    /// #33: valid .int passes through.
    func testRequiredInt64AcceptsValidInt() throws {
        XCTAssertEqual(try requiredInt64(["user_id": .int(42)], "user_id"), 42)
    }

    /// Security verify nit: lock the truncation-safety contract directly at the
    /// #33 parser seam. A fractional `.double` is rejected (`Int(exactly:)` is
    /// nil), so no truncated id can reach a destructive handler. Previously this
    /// was only covered transitively via the limit / max_messages tests.
    func testRequiredInt64RejectsFractionalDouble() {
        XCTAssertThrowsError(try requiredInt64(["chat_id": .double(12345.6)], "chat_id")) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description, "chat_id must be an integer")
        }
    }
}
