import XCTest
@testable import TelegramAllLib

/// Verifies that `sinceDate` / `untilDate` filters apply on the Swift client side
/// independently of `maxMessages`.
///
/// Covers spec requirement:
/// "Client-side date range filtering independent of pagination"
///
/// A single-page retrieval combined with a date filter MUST be a valid invocation —
/// the method MUST NOT throw a parameter-conflict error, and MUST apply the filter
/// to the single fetched batch.
final class TDLibClientDateFilterTests: XCTestCase {

    private func msg(id: Int64, date: Date, text: String = "m") -> [String: Any] {
        ["id": id, "date": Int(date.timeIntervalSince1970), "text": text]
    }

    // MARK: - Since lower bound

    func testSinceDateIncludesBoundaryAndLater() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let raw: [[String: Any]] = [
            msg(id: 3, date: since.addingTimeInterval(60)),
            msg(id: 2, date: since),                           // boundary inclusive
            msg(id: 1, date: since.addingTimeInterval(-60)),   // excluded
        ]
        let filtered = filterMessagesByDate(raw, since: since, until: nil)
        let ids = filtered.compactMap { $0["id"] as? Int64 }.sorted()
        XCTAssertEqual(ids, [2, 3],
                       "sinceDate MUST be inclusive at the exact boundary")
    }

    // MARK: - Until upper bound

    func testUntilDateIncludesBoundaryAndEarlier() {
        let until = Date(timeIntervalSince1970: 1_700_000_000)
        let raw: [[String: Any]] = [
            msg(id: 3, date: until.addingTimeInterval(60)),    // excluded
            msg(id: 2, date: until),                           // boundary inclusive
            msg(id: 1, date: until.addingTimeInterval(-60)),
        ]
        let filtered = filterMessagesByDate(raw, since: nil, until: until)
        let ids = filtered.compactMap { $0["id"] as? Int64 }.sorted()
        XCTAssertEqual(ids, [1, 2],
                       "untilDate MUST be inclusive at the exact boundary")
    }

    // MARK: - Both bounds

    func testBothBoundsFiltersToClosedInterval() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let until = since.addingTimeInterval(3600)  // one-hour window
        let raw: [[String: Any]] = [
            msg(id: 1, date: since.addingTimeInterval(-60)),       // below since → excluded
            msg(id: 2, date: since),                               // at since → included
            msg(id: 3, date: since.addingTimeInterval(1800)),      // middle → included
            msg(id: 4, date: until),                               // at until → included
            msg(id: 5, date: until.addingTimeInterval(60)),        // above until → excluded
        ]
        let filtered = filterMessagesByDate(raw, since: since, until: until)
        let ids = filtered.compactMap { $0["id"] as? Int64 }.sorted()
        XCTAssertEqual(ids, [2, 3, 4],
                       "Both bounds MUST filter to the closed interval [since, until]")
    }

    // MARK: - Nil bounds

    func testBothBoundsNilReturnsOriginal() {
        let raw: [[String: Any]] = [
            msg(id: 1, date: Date(timeIntervalSince1970: 1)),
            msg(id: 2, date: Date(timeIntervalSince1970: 2)),
        ]
        let filtered = filterMessagesByDate(raw, since: nil, until: nil)
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - Independence from maxMessages semantics

    /// Single-page retrieval + date filter is a valid invocation. The filter applies
    /// to the fetched batch; the result MAY contain fewer messages than the original
    /// page size, which MUST NOT be treated as an error.
    func testSinglePagePlusFilterYieldsSubset() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        // Simulate a 100-message TDLib batch where only 40 fall within range.
        let raw: [[String: Any]] = (0..<100).map { i in
            let offset = TimeInterval((i - 60) * 60) // 60 msgs before since, 40 after
            return msg(id: Int64(100 - i), date: since.addingTimeInterval(offset))
        }
        let filtered = filterMessagesByDate(raw, since: since, until: nil)
        XCTAssertEqual(filtered.count, 40,
                       "Single-page + date filter MUST return subset; count MAY be less than page size")
    }

    // MARK: - Messages with unparseable date

    func testMessageWithoutDateFieldIsRetained() {
        let raw: [[String: Any]] = [
            ["id": 1, "text": "no-date"],
            ["id": 2, "date": 1_700_000_000, "text": "ok"],
        ]
        let filtered = filterMessagesByDate(
            raw,
            since: Date(timeIntervalSince1970: 1_700_000_000),
            until: nil
        )
        XCTAssertEqual(filtered.count, 2,
                       "Messages lacking a parseable `date` MUST be retained under all filters")
    }

    // MARK: - messageDate helper

    func testMessageDateParsesIntAndInt64AndDouble() {
        let intDict: [String: Any] = ["date": 1_700_000_000]
        let int64Dict: [String: Any] = ["date": Int64(1_700_000_000)]
        let doubleDict: [String: Any] = ["date": 1_700_000_000.5]
        let expected = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(messageDate(intDict), expected)
        XCTAssertEqual(messageDate(int64Dict), expected)
        XCTAssertEqual(messageDate(doubleDict)?.timeIntervalSince1970 ?? 0, 1_700_000_000.5, accuracy: 0.01)
    }

    func testMessageDateReturnsNilWhenMissing() {
        XCTAssertNil(messageDate(["id": 1]))
        XCTAssertNil(messageDate(["date": "not-a-number"]))
    }
}
