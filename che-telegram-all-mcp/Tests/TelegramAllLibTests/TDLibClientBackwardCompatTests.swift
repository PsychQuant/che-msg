import XCTest
@testable import TelegramAllLib

// MARK: - Compile-only signature assertions
//
// These file-scope functions are never invoked at runtime. If they compile, the
// public surface of `TDLibClient.getChatHistory` includes both the original three-
// parameter form AND the extended six-parameter form. This is how we assert
// backward compatibility without instantiating a TDLibClient at test time —
// TDLib's receive loop is process-global and cannot tolerate multiple instances
// in one test run.

@discardableResult
private func _compileAssertOriginalGetChatHistorySignature(
    _ client: TDLibClient
) async throws -> String {
    // Original three-parameter call site — this is what existing code looks like.
    try await client.getChatHistory(chatId: 0, limit: 1, fromMessageId: 0)
}

@discardableResult
private func _compileAssertExtendedGetChatHistorySignature(
    _ client: TDLibClient
) async throws -> String {
    try await client.getChatHistory(
        chatId: 0,
        limit: 1,
        fromMessageId: 0,
        maxMessages: 500,
        sinceDate: Foundation.Date(timeIntervalSince1970: 0),
        untilDate: Foundation.Date()
    )
}

@discardableResult
private func _compileAssertDefaultedExtendedSignature(
    _ client: TDLibClient
) async throws -> String {
    // All new parameters have defaults — caller can pass only the original three
    // by name and overload resolution still picks the extended method cleanly.
    try await client.getChatHistory(chatId: 123)
}

/// Verifies that existing call sites of `TDLibClient.getChatHistory` — using only the
/// original three parameters — continue to compile and to route through the
/// backward-compatible single-page codepath.
///
/// Covers spec requirement: "Backward-compatible single-page retrieval"
/// Corresponds to design decision: "Library 層單一 function 承擔兩種語意"
/// (back-compat branch: when maxMessages/sinceDate/untilDate are all nil, no new
/// per-message processing occurs).
final class TDLibClientBackwardCompatTests: XCTestCase {

    /// If this test file compiles, the three compile-assertion functions above
    /// verified that both the original and extended signatures of
    /// `TDLibClient.getChatHistory` are callable and overload-resolve correctly.
    func testGetChatHistorySignatureMatrix() {
        XCTAssertTrue(true, "Signatures compile at file scope above")
    }

    /// When the caller provides no bulk/filter params, `filterMessagesByDate` is a no-op.
    /// This guarantees the back-compat branch returns the raw TDLib batch untouched.
    func testFilterIsNoOpWhenNoBoundsProvided() {
        let raw: [[String: Any]] = [
            ["id": 1, "date": 1_700_000_000, "text": "a"],
            ["id": 2, "date": 1_700_100_000, "text": "b"],
        ]
        let filtered = filterMessagesByDate(raw, since: nil, until: nil)

        XCTAssertEqual(filtered.count, raw.count,
                       "Back-compat path MUST return raw batch unchanged")
        for (original, passed) in zip(raw, filtered) {
            XCTAssertEqual(original["id"] as? Int, passed["id"] as? Int)
        }
    }

    /// The pagination accumulation helper is never reached on the back-compat path,
    /// but we still verify its termination when it is hit with an empty batch: this
    /// mirrors the "conversation start reached" case that the back-compat path does
    /// NOT have to handle (because it always makes exactly one call).
    func testPaginationAccumulatorStopsOnEmptyBatch() {
        let step = accumulatePaginationBatch(
            current: [],
            newBatch: [],
            sinceDate: nil,
            untilDate: nil,
            maxMessages: 100
        )
        XCTAssertEqual(step.accumulated.count, 0)
        XCTAssertFalse(step.shouldContinue,
                       "Empty batch MUST terminate pagination (no older messages)")
        XCTAssertNil(step.nextFromMessageId)
    }
}
