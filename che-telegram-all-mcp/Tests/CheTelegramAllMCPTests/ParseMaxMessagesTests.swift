import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `max_messages`: #4 explicit override, #8 type enforcement, and #23 the dump's default cap.
/// Moved out of ServerHandlerLogicTests.swift (#26) without changes.
final class ParseMaxMessagesTests: XCTestCase {

    // MARK: - #4: max_messages explicit override

    func testExplicitMaxMessagesOverridesImplicit() throws {
        let args: [String: Value] = [
            "chat_id": .int(100),
            "limit": .int(50),
            "max_messages": .int(5),
        ]
        let parsed = try parseGetChatHistoryArgs(args)
        XCTAssertEqual(parsed.maxMessages, 5,
                       "explicit max_messages should win over fromMsgId==0 default")
    }

    func testMaxMessagesRejectsZeroOrNegative() {
        // #11: error message text is part of the MCP contract — assert prefix
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(0),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "max_messages must be positive; got 0")
        }
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(-5),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "max_messages must be positive; got -5")
        }
    }

    func testMaxMessagesRejectsOverCap() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(50_000),
        ])) { error in
            XCTAssertEqual(
                (error as? HandlerArgError)?.description,
                "max_messages exceeds 10_000 cap; got 50000. Use since_date/until_date to narrow the range."
            )
        }
    }

    func testMaxMessagesAtCapAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(10_000),
        ])
        XCTAssertEqual(parsed.maxMessages, 10_000)
    }

    /// Boundary regression for #15-C2 — first value above the cap (10_001)
    /// must be rejected. Without this test an off-by-one change like
    /// `if mm > 10_001` would silently widen the cap (10_000 still accepted,
    /// 50_000 still rejected, but 10_001 leaks through).
    func testMaxMessagesAt10001Rejected() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(10_001),
        ]))
    }

    /// Symmetric downward boundary guard. Devil's-Advocate finding from #15
    /// verify: testMaxMessagesAt10001Rejected only catches mutations that
    /// *widen* the cap (e.g. `> 10_500`). A mutation that *shrinks* the cap
    /// (`if mm >= 10_000` or `if mm > 9_999`) would make 10_000 throw too,
    /// but the existing testMaxMessagesAtCapAccepted catches that case for
    /// the boundary itself. This test seals the next-lower value (9_999),
    /// catching any mutation that pushes the cap down to 9_999 or below
    /// (e.g. `> 9_998`).
    func testMaxMessagesAt9999Accepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(9_999),
        ])
        XCTAssertEqual(parsed.maxMessages, 9_999)
    }

    // MARK: - #8 A1 (subsumes #20): max_messages type enforcement

    /// `.string("100")` should be coerced to 100 (consistent with int64ArgValue's
    /// dual-path semantics for chat_id) — pre-existing behavior for callers that
    /// quote integers in JSON.
    func testMaxMessagesAsStringAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .string("100"),
        ])
        XCTAssertEqual(parsed.maxMessages, 100)
    }

    /// `.string("0")` MUST throw — old behavior silently fell back to the
    /// default (limit for get_chat_history, 5000 for dump), bypassing the
    /// `<= 0` cap entirely (#8 A1, #20).
    func testMaxMessagesAsStringZeroRejected() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .string("0"),
        ]))
    }

    /// Non-numeric string must throw with explicit error (caller intent
    /// ambiguous — silent fallback was the bug).
    func testMaxMessagesAsStringInvalidRejected() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .string("not-a-number"),
        ]))
    }

    /// Whole-number `.double` (e.g. `5000.0`) MUST be accepted — JS / Python
    /// JSON encoders routinely emit integers as `5000.0` per JSON spec,
    /// and MCP SDK's `Int(value, strict: false)` correctly coerces via
    /// `Int(exactly:)`. Verify-stage Devil's Advocate caught the prior
    /// implementation rejecting these as a regression for legitimate callers.
    func testMaxMessagesAsWholeDoubleAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .double(5000.0),
        ])
        XCTAssertEqual(parsed.maxMessages, 5000)
    }

    /// Fractional `.double` MUST throw — `Int(exactly: 0.5)` is nil; user
    /// intent ambiguous (round? truncate?). Reject loudly instead.
    func testMaxMessagesAsFractionalDoubleRejected() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .double(0.5),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "max_messages must be an integer")
        }
    }

    /// `.double(20000.0)` is whole-number → coerces to Int(20000) → THEN
    /// the cap check throws "exceeds 10_000 cap". Different error path
    /// from fractional double; assert the cap message specifically.
    func testMaxMessagesAsWholeDoubleOverCapRejected() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .double(20000.0),
        ])) { error in
            XCTAssertEqual(
                (error as? HandlerArgError)?.description,
                "max_messages exceeds 10_000 cap; got 20000. Use since_date/until_date to narrow the range."
            )
        }
    }

    func testDumpMaxMessagesAsStringZeroRejected() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .string("0"),
        ]))
    }

    /// Dump parser parity for #8 DA finding fix — whole-number doubles
    /// over cap must still throw cap error, not type error.
    func testDumpMaxMessagesAsDoubleOverCapRejected() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .double(20000.0),
        ])) { error in
            XCTAssertTrue(
                ((error as? HandlerArgError)?.description ?? "")
                    .hasPrefix("max_messages exceeds 10_000 cap")
            )
        }
    }

    /// Dump parser parity — whole-number doubles within cap must coerce.
    func testDumpMaxMessagesAsWholeDoubleAccepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .double(8000.0),
        ])
        XCTAssertEqual(parsed.maxMessages, 8000)
    }

    // MARK: - #23: parseDumpChatToMarkdownArgs default-5000 cap (verify F2 — mutation-resistant)

    /// #23: when `max_messages` is omitted, default 5000 still flows through
    /// `validateMaxMessagesCap`. Pre-#23, the default literal 5000 silently
    /// bypassed the cap. Currently `cap = 10_000 > 5000`, so the default
    /// passes — this happy-path test locks the value but does NOT verify
    /// the cap call (mutation: removing cap call from default path leaves
    /// this test passing). The mutation-resistant guard is
    /// `testParseMaxMessagesWithDefaultAppliesCapToDefaultPath` below.
    func testParseDumpDefaultMaxMessagesRespectsCap() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.maxMessages, 5000,
                       "default max_messages must remain 5000 (and pass cap)")
    }

    /// #23 verify F2 — mutation-resistant cap check on default path.
    /// `parseMaxMessagesWithDefault` flows `defaultValue` through
    /// `validateMaxMessagesCap`. Pass a default that exceeds the 10_000 cap
    /// → must throw. Deleting `try validateMaxMessagesCap(defaultValue)`
    /// from the default branch (HandlerArgs.swift `parseMaxMessagesWithDefault`)
    /// makes this test fail — that's the mutation guard the placebo
    /// `testParseDumpDefaultMaxMessagesRespectsCap` could not provide.
    func testParseMaxMessagesWithDefaultAppliesCapToDefaultPath() {
        XCTAssertThrowsError(try parseMaxMessagesWithDefault([:], default: 11000)) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "max_messages exceeds 10_000 cap; got 11000. Use since_date/until_date to narrow the range.")
        }
    }

    /// `parseMaxMessagesWithDefault` happy path: explicit value wins, default ignored.
    func testParseMaxMessagesWithDefaultExplicitWinsOverDefault() throws {
        let result = try parseMaxMessagesWithDefault(["max_messages": .int(50)], default: 5000)
        XCTAssertEqual(result, 50)
    }

    /// `parseMaxMessagesWithDefault` honors `defaultValue` when key absent.
    func testParseMaxMessagesWithDefaultUsesDefaultWhenAbsent() throws {
        let result = try parseMaxMessagesWithDefault([:], default: 5000)
        XCTAssertEqual(result, 5000)
    }
}
