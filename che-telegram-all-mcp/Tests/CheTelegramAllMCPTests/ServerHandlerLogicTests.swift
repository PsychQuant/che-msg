import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// Tests for `get_chat_history` argument parsing — the pure function
/// `parseGetChatHistoryArgs` extracted from the MCP handler.
///
/// Protects #3 (fromMsgId==0 → maxMessages=limit auto-pagination) and
/// #4 (since_date/until_date/max_messages wiring) against regression.
final class ServerHandlerLogicTests: XCTestCase {

    // MARK: - #3 regression: fromMsgId==0 auto-pagination

    func testFromMsgIdZeroDefaultsMaxMessagesToLimit() throws {
        let args: [String: Value] = [
            "chat_id": .int(100),
            "limit": .int(50),
        ]
        let parsed = try parseGetChatHistoryArgs(args)
        XCTAssertEqual(parsed.chatId, 100)
        XCTAssertEqual(parsed.limit, 50)
        XCTAssertEqual(parsed.fromMessageId, 0)
        XCTAssertEqual(parsed.maxMessages, 50,
                       "fromMsgId==0 should default maxMessages to limit (#3)")
    }

    func testFromMsgIdNonZeroLeavesMaxMessagesNil() throws {
        let args: [String: Value] = [
            "chat_id": .int(100),
            "limit": .int(50),
            "from_message_id": .int(12345),
        ]
        let parsed = try parseGetChatHistoryArgs(args)
        XCTAssertEqual(parsed.fromMessageId, 12345)
        XCTAssertNil(parsed.maxMessages,
                     "fromMsgId>0 should keep maxMessages nil (backward-compat)")
    }

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

    // MARK: - #10 C2: since_date / until_date range sanity check

    /// `since > until` previously silently filtered to empty result with no
    /// error. New: throws "since_date must be earlier than until_date".
    func testSinceAfterUntilThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-12-31"),
            "until_date": .string("2026-01-01"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "since_date must be earlier than until_date")
        }
    }

    /// Boundary: same date → since at 00:00 < until at 23:59:59, should pass.
    func testSinceEqualsUntilSameDayAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-04-17"),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.sinceDate)
        XCTAssertNotNil(parsed.untilDate)
    }

    /// Only since: range check skipped (no upper bound to compare).
    func testOnlySinceAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.sinceDate)
        XCTAssertNil(parsed.untilDate)
    }

    /// Only until: range check skipped.
    func testOnlyUntilAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNil(parsed.sinceDate)
        XCTAssertNotNil(parsed.untilDate)
    }

    /// Dump parser parity for #10 C2.
    func testDumpSinceAfterUntilThrows() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "since_date": .string("2026-12-31"),
            "until_date": .string("2026-01-01"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "since_date must be earlier than until_date")
        }
    }

    // MARK: - #4: date parsing

    func testSinceDateValidParsed() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.sinceDate)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour],
            from: parsed.sinceDate!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 0, "since_date = start of day")
    }

    func testUntilDateUsesEndOfDay() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.untilDate)
        // #15-C3: assert year/month/day too — without these a TZ drift bug
        // could shift `until_date` to a different calendar day while keeping
        // hour/min/sec at 23:59:59 (same wall clock, wrong date).
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: parsed.untilDate!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    func testInvalidDateFormatThrows() {
        // #11: error message text is part of the MCP contract
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026/04/17"),
        ])) { error in
            XCTAssertEqual(
                (error as? DateParseError)?.description,
                "Date format invalid: expected YYYY-MM-DD, got \"2026/04/17\""
            )
        }
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("not-a-date"),
        ])) { error in
            XCTAssertEqual(
                (error as? DateParseError)?.description,
                "Date format invalid: expected YYYY-MM-DD, got \"not-a-date\""
            )
        }
    }

    // MARK: - Required field validation

    func testMissingChatIdThrows() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseGetChatHistoryArgs([:])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "limit": .int(50),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
    }

    // MARK: - Defaults

    func testDefaultLimitIs50() throws {
        let parsed = try parseGetChatHistoryArgs(["chat_id": .int(100)])
        XCTAssertEqual(parsed.limit, 50,
                       "default limit should be 50")
    }

    // MARK: - #12 backward-compat: numeric-string chat_id / from_message_id

    /// `int64ArgValue` accepts `.string("123")` for callers that quote integers
    /// in JSON (legacy MCP clients). Lock this dual-path so a refactor that
    /// drops string fallback would be caught.
    func testChatIdAsStringAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .string("100"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
    }

    func testFromMessageIdAsStringAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "from_message_id": .string("12345"),
        ])
        XCTAssertEqual(parsed.fromMessageId, 12345)
    }

    /// #22: non-numeric string for `chat_id` now throws a type-mismatch
    /// error instead of the misleading "chat_id is required". Pre-#22,
    /// `int64ArgValue` silently returned nil on parse-fail, so the caller
    /// threw "is required" — leading the user to check args structure
    /// instead of value type. Post-#22, `int64ArgValueStrict` distinguishes
    /// absent (nil → caller decides) vs. wrong type (throws with quoted
    /// value for debug clarity).
    func testChatIdAsStringInvalidThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .string("not-a-number"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"not-a-number\"")
        }
    }

    /// #22 parity for `from_message_id` — same type-mismatch handling via
    /// `int64ArgValueStrict`. Without this test, a regression that re-narrows
    /// strictness only to `chat_id` could go unnoticed.
    func testFromMessageIdAsStringInvalidThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "from_message_id": .string("garbage"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "from_message_id must be an integer; got \"garbage\"")
        }
    }

    /// #22 parity for `parseDumpChatToMarkdownArgs.chat_id` — confirms the
    /// strict-helper upgrade applied to both parsers, not just
    /// `parseGetChatHistoryArgs`.
    func testDumpChatIdAsStringInvalidThrows() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .string("not-a-number"),
            "output_path": .string("/tmp/x.md"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"not-a-number\"")
        }
    }

    func testDumpChatIdAsStringAccepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .string("100"),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
    }

    // MARK: - #13: parseDumpChatToMarkdownArgs

    func testDumpRequiresChatId() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "output_path": .string("/tmp/x.md"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
    }

    func testDumpRequiresOutputPath() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "output_path is required")
        }
    }

    func testDumpDefaultMaxMessagesIs5000() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
        XCTAssertEqual(parsed.outputPath, "/tmp/x.md")
        XCTAssertEqual(parsed.maxMessages, 5000,
                       "default max_messages for dump_chat_to_markdown is 5000 (different from get_chat_history)")
    }

    func testDumpDefaultSelfLabel() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.selfLabel, "我", "default self_label is 我")
    }

    func testDumpExplicitSelfLabel() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "self_label": .string("Alice"),
        ])
        XCTAssertEqual(parsed.selfLabel, "Alice")
    }

    /// Boundary parity with #15-C2 — dump handler must enforce the same
    /// upward cap. Without this, future cap policy changes in
    /// `validateMaxMessagesCap` could silently drift here.
    func testDumpMaxMessagesAt10001Rejected() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(10_001),
        ]))
    }

    func testDumpMaxMessagesAt10000Accepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(10_000),
        ])
        XCTAssertEqual(parsed.maxMessages, 10_000)
    }

    /// Symmetric downward boundary parity with #15 DA finding.
    func testDumpMaxMessagesAt9999Accepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(9_999),
        ])
        XCTAssertEqual(parsed.maxMessages, 9_999)
    }

    func testDumpMaxMessagesRejectsZeroOrNegative() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(0),
        ]))
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(-1),
        ]))
    }

    func testDumpInvalidDateThrows() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "since_date": .string("2026/04/17"),
        ]))
    }

    /// Parity with #15-C3 — until_date must hit end-of-day with full
    /// year/month/day assertions to catch TZ drift bugs.
    func testDumpUntilDateUsesEndOfDay() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.untilDate)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: parsed.untilDate!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    // MARK: - #23: parseDumpChatToMarkdownArgs default-5000 cap

    /// #23: when `max_messages` is omitted, default 5000 still flows through
    /// `validateMaxMessagesCap`. Pre-#23, the default literal 5000 silently
    /// bypassed the cap (since `parseMaxMessages` only validated explicit
    /// args). Currently `cap = 10_000 > 5000`, so the explicit default
    /// passes; this test locks the structural invariant that the default
    /// path is gated by the cap. If a future policy reduces the cap below
    /// 5000, this test will (intentionally) start failing — that's the
    /// signal to also update the default literal in lockstep with the cap.
    func testParseDumpDefaultMaxMessagesRespectsCap() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.maxMessages, 5000,
                       "default max_messages must remain 5000 (and pass cap)")
    }

    // MARK: - #25: parseLimit (numeric arg strictness)

    /// #25: `parseLimit` rejects non-numeric strings (parity with
    /// `parseMaxMessages` #8 A1). Pre-#25, `args["limit"]?.intValue ?? 50`
    /// silently fell back to 50 for `.string("not-a-number")`.
    func testLimitRejectsInvalidString() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .string("not-a-number"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "limit must be an integer")
        }
    }

    /// #25 parity with `parseMaxMessages`: JS / Python JSON encoders emit
    /// integers as doubles (`50.0`), MCP transport surfaces them as
    /// `.double(50.0)`. `parseLimit` accepts whole-number doubles per
    /// MCP SDK's `Int(_:strict:false)` (parity with #8 commit `f0203ac`).
    func testLimitAcceptsWholeNumberDouble() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .double(50.0),
        ])
        XCTAssertEqual(parsed.limit, 50)
    }

    /// #25: `parseLimit` rejects zero (would silently produce empty results
    /// upstream). Mirrors `parseMaxMessages` `validateMaxMessagesCap`
    /// positive-check pattern.
    func testLimitRejectsZeroOrNegative() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .int(0),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "limit must be positive; got 0")
        }
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .int(-5),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "limit must be positive; got -5")
        }
    }

    /// #25: `parseLimit` accepts numeric strings (parity with
    /// `parseMaxMessages` legacy MCP client behavior).
    func testLimitAcceptsNumericString() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .string("75"),
        ])
        XCTAssertEqual(parsed.limit, 75)
    }
}
