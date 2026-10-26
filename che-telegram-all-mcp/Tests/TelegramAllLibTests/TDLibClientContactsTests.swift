import XCTest
@testable import TelegramAllLib

/// #34: falsifiable coverage for the contact fan-out bound.
///
/// `getContacts` loops one `getUser` per contact id over `result.userIds`.
/// TDLib's `getContacts` has no server-side limit, so the fix truncates the id
/// list client-side via `boundedContactIds(_:limit:)` before the loop. The
/// loop itself needs a live TDLib connection (untestable in place), so this
/// pure helper is where the bound is proven. A `parseLimit`-only test would be
/// a placebo — it bounds the *arg*, not the fan-out.
final class TDLibClientContactsTests: XCTestCase {

    /// More ids than the limit → truncated to the first `limit` (the bound).
    /// Mutation guard: replacing `Array(ids.prefix(limit))` with `ids` (the
    /// pre-#34 unbounded behavior) makes this fail with count 10 != 5.
    func testBoundedContactIdsTruncatesOverLimit() {
        let ids: [Int64] = Array(1...10)
        let bounded = boundedContactIds(ids, limit: 5)
        XCTAssertEqual(bounded, [1, 2, 3, 4, 5])
    }

    /// Fewer ids than the limit → all returned (no padding, no truncation).
    func testBoundedContactIdsUnderLimitReturnsAll() {
        let ids: [Int64] = [10, 20, 30]
        XCTAssertEqual(boundedContactIds(ids, limit: 5), [10, 20, 30])
    }

    /// Exactly at the limit → all returned.
    func testBoundedContactIdsAtLimitReturnsAll() {
        let ids: [Int64] = [1, 2, 3, 4, 5]
        XCTAssertEqual(boundedContactIds(ids, limit: 5), ids)
    }

    /// Empty contact list → empty (no fan-out at all).
    func testBoundedContactIdsEmpty() {
        XCTAssertEqual(boundedContactIds([], limit: 5), [])
    }

    /// The default-200 path (no-arg callers like the CLI/E2E): a list larger
    /// than the default is bounded to 200.
    func testBoundedContactIdsDefaultBound() {
        let ids: [Int64] = Array(1...500)
        XCTAssertEqual(boundedContactIds(ids, limit: 200).count, 200)
    }

    /// `getContacts(limit:)` is public, so a library caller can pass any
    /// value the MCP handler's `parseLimit` would refuse: a negative limit
    /// must not trap in `prefix`, and the 10_000 cap holds there too.
    func testBoundedContactIdsClampsOutOfRangeLimits() {
        let ids: [Int64] = Array(1...10_005)
        XCTAssertEqual(boundedContactIds(ids, limit: -1), [])
        XCTAssertEqual(boundedContactIds(ids, limit: 0), [])
        XCTAssertEqual(boundedContactIds(ids, limit: 100_000).count, 10_000)
    }

    /// The handler and the library call cannot run without TDLib, so their
    /// wiring is pinned in the source: the handler parses `limit` with the
    /// 200 default and passes it on, and getContacts bounds the ids it loops
    /// over (verify of #34: each of these could change with every test green).
    func testTheLimitIsWiredFromTheHandlerToTheLoop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = try String(contentsOf: root.appendingPathComponent("Sources/CheTelegramAllMCPCore/Server.swift"), encoding: .utf8)
        let handler = try XCTUnwrap(server.range(of: #"case "get_contacts":\s*let limit = try parseLimit\(args, default: 200\)\s*result = try await tdlib\.getContacts\(limit: limit\)"#, options: .regularExpression))
        XCTAssertFalse(handler.isEmpty)
        let client = try String(contentsOf: root.appendingPathComponent("Sources/TelegramAllLib/TDLibClient.swift"), encoding: .utf8)
        XCTAssertNotNil(client.range(of: #"for userId in boundedContactIds\(result\.userIds, limit: limit\)"#, options: .regularExpression))
        XCTAssertNotNil(server.range(of: #""limit": prop\("integer", "Max contacts to return \(default 200, max 10000\)"\)"#, options: .regularExpression))
    }
}

