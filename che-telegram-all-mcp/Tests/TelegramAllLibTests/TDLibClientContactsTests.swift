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
}
