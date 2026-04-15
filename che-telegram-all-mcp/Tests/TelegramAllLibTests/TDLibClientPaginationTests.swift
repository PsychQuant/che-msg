import XCTest
@testable import TelegramAllLib

/// Verifies pagination termination logic in `accumulatePaginationBatch`.
///
/// Covers spec requirement: "Bulk chat history retrieval with bounded termination"
/// Corresponds to design decision: "分頁方向 newest → oldest + early-terminate"
///
/// Three termination conditions are exercised:
///   1. Accumulated count reaches `maxMessages`.
///   2. TDLib returns an empty batch (conversation start reached).
///   3. Current batch contains a message older than `sinceDate` (early-terminate).
final class TDLibClientPaginationTests: XCTestCase {

    // MARK: - Fixture helpers

    private func msg(id: Int64, date: Date) -> [String: Any] {
        ["id": id, "date": Int(date.timeIntervalSince1970), "text": "m\(id)"]
    }

    private func batch(ids: [Int64], baseDate: Date, stepSeconds: TimeInterval = -60) -> [[String: Any]] {
        // Messages are ordered newest first (TDLib convention), so dates decrease with index.
        ids.enumerated().map { idx, id in
            msg(id: id, date: baseDate.addingTimeInterval(stepSeconds * Double(idx)))
        }
    }

    // MARK: - Termination: maxMessages cap

    /// When accumulated count hits `maxMessages`, pagination MUST stop and the
    /// accumulation MUST be trimmed to exactly `maxMessages`.
    func testTerminatesAtMaxMessagesCap() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstBatch = batch(ids: [100, 99, 98, 97, 96], baseDate: base)

        let step = accumulatePaginationBatch(
            current: [],
            newBatch: firstBatch,
            sinceDate: nil,
            untilDate: nil,
            maxMessages: 3
        )

        XCTAssertEqual(step.accumulated.count, 3,
                       "Accumulation MUST be trimmed to maxMessages")
        XCTAssertFalse(step.shouldContinue,
                       "Hitting maxMessages MUST terminate pagination")
        XCTAssertNil(step.nextFromMessageId)
    }

    /// maxMessages across multiple batches: cap enforcement happens on final batch that
    /// pushes accumulation over the limit.
    func testTerminatesAtCapAcrossMultipleBatches() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstBatch = batch(ids: [100, 99, 98], baseDate: base)
        let secondBatch = batch(ids: [97, 96, 95, 94, 93], baseDate: base.addingTimeInterval(-300))

        let s1 = accumulatePaginationBatch(
            current: [],
            newBatch: firstBatch,
            sinceDate: nil,
            untilDate: nil,
            maxMessages: 5
        )
        XCTAssertTrue(s1.shouldContinue)
        XCTAssertEqual(s1.accumulated.count, 3)

        let s2 = accumulatePaginationBatch(
            current: s1.accumulated,
            newBatch: secondBatch,
            sinceDate: nil,
            untilDate: nil,
            maxMessages: 5
        )
        XCTAssertEqual(s2.accumulated.count, 5,
                       "Final accumulation MUST be trimmed to cap exactly")
        XCTAssertFalse(s2.shouldContinue)
    }

    // MARK: - Termination: conversation start (empty batch)

    /// When TDLib returns an empty batch, the conversation start has been reached
    /// and pagination MUST stop.
    func testTerminatesOnEmptyBatch() {
        let existing: [[String: Any]] = [
            ["id": 1, "date": 1_700_000_000, "text": "old"],
        ]
        let step = accumulatePaginationBatch(
            current: existing,
            newBatch: [],
            sinceDate: nil,
            untilDate: nil,
            maxMessages: 5000
        )

        XCTAssertEqual(step.accumulated.count, 1,
                       "Accumulation MUST preserve prior messages on empty batch")
        XCTAssertFalse(step.shouldContinue,
                       "Empty batch MUST terminate pagination (no older messages)")
        XCTAssertNil(step.nextFromMessageId)
    }

    // MARK: - Termination: sinceDate early-terminate

    /// When any message in the current batch is older than `sinceDate`, pagination MUST
    /// stop. Messages inside the range MUST still be accumulated (date filter applied).
    func testTerminatesWhenBatchCrossesSinceBoundary() {
        let sinceDate = Date(timeIntervalSince1970: 1_700_000_000)
        // Batch spans from 30s after sinceDate down to 30s before — boundary crossed.
        let crossingBatch: [[String: Any]] = [
            msg(id: 100, date: sinceDate.addingTimeInterval(30)),
            msg(id: 99,  date: sinceDate.addingTimeInterval(0)),
            msg(id: 98,  date: sinceDate.addingTimeInterval(-30)),   // older than sinceDate
            msg(id: 97,  date: sinceDate.addingTimeInterval(-60)),   // older than sinceDate
        ]

        let step = accumulatePaginationBatch(
            current: [],
            newBatch: crossingBatch,
            sinceDate: sinceDate,
            untilDate: nil,
            maxMessages: 5000
        )

        XCTAssertEqual(step.accumulated.count, 2,
                       "Only messages at or after sinceDate MUST be accumulated")
        XCTAssertEqual(step.accumulated.compactMap { $0["id"] as? Int64 }.sorted(by: >), [100, 99])
        XCTAssertFalse(step.shouldContinue,
                       "Boundary-crossing batch MUST terminate pagination")
    }

    /// When the batch is fully inside the `sinceDate` range, pagination MUST continue.
    func testContinuesWhenBatchFullyInsideRange() {
        let sinceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let insideBatch = batch(
            ids: [100, 99, 98],
            baseDate: sinceDate.addingTimeInterval(600)
        )

        let step = accumulatePaginationBatch(
            current: [],
            newBatch: insideBatch,
            sinceDate: sinceDate,
            untilDate: nil,
            maxMessages: 5000
        )

        XCTAssertEqual(step.accumulated.count, 3)
        XCTAssertTrue(step.shouldContinue,
                      "Batch fully inside sinceDate range MUST NOT terminate pagination")
        XCTAssertEqual(step.nextFromMessageId, 98,
                       "Next from_message_id MUST be the oldest (lowest) id in the batch")
    }

    // MARK: - batchCrossesSinceBoundary helper

    func testBatchCrossesSinceBoundaryWithNilSince() {
        let b = batch(ids: [1, 2], baseDate: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertFalse(batchCrossesSinceBoundary(b, sinceDate: nil),
                       "Nil sinceDate MUST never trigger early-terminate")
    }

    func testBatchCrossesSinceBoundaryDetectsOlderMessage() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let b: [[String: Any]] = [
            msg(id: 1, date: since.addingTimeInterval(60)),
            msg(id: 2, date: since.addingTimeInterval(-60)),
        ]
        XCTAssertTrue(batchCrossesSinceBoundary(b, sinceDate: since))
    }
}
