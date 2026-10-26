import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `parseLimit` (#25): numeric strictness, the upper cap, and the verify follow-ups.
/// Split out of ServerHandlerLogicTests.swift (#26).
final class ParseLimitTests: XCTestCase {

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

    // MARK: - #25 verify F4: parseLimit upper cap

    /// #25 verify F4 — `parseLimit` rejects values over the shared 10_000
    /// cap. Closes the parity gap vs. `parseMaxMessages`. Without this,
    /// MCP callers could pass `limit: 999_999_999` straight into TDLib
    /// (`getChats` then iterates one `getChat` per id).
    func testLimitRejectsOverCap() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .int(20000),
        ])) { error in
            assertCapError(error, field: "limit", got: 20000)
        }
    }

    /// #25 verify F4 — at-cap boundary accepted.
    func testLimitAtCapAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .int(10000),
        ])
        XCTAssertEqual(parsed.limit, 10000)
    }

    // MARK: - Verify follow-up (Codex + logic L2 + devil's-advocate): parseLimit
    //         default/.null cap parity + mutation guard

    /// `limit: .null` returns the caller's default. Mutation guard for the
    /// `.null` branch in `parseLimit`: deleting `if case .null = raw { ... }`
    /// makes `.null` fall through to `Int(_:strict:false)` → nil → wrongly
    /// throw "limit must be an integer". No prior test covered this branch
    /// (flagged by logic L2 + devil's-advocate as a surviving mutant).
    func testLimitNullUsesDefault() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "limit": .null,
        ])
        XCTAssertEqual(parsed.limit, 50)  // parseGetChatHistoryArgs default
    }

    /// `parseLimit` default path flows through `validateLimitCap` (parity with
    /// `parseMaxMessagesWithDefault`, #23). A future callsite passing a default
    /// over the 10_000 cap must throw. Mutation-resistant: deleting the cap
    /// call on the default branch makes this test fail. Closes the #25 edge
    /// Codex flagged (default path silently bypassed the cap).
    func testLimitDefaultOverCapRejected() {
        XCTAssertThrowsError(try parseLimit([:], default: 20000)) { error in
            assertCapError(error, field: "limit", got: 20000)
        }
    }
}
