import XCTest
@testable import TelegramAllLib

/// Verifies batch sender resolution with fallback.
///
/// Covers spec requirement: "Batch sender resolution with fallback"
/// Corresponds to design decision: "Sender name 批次 resolve + cache"
final class MarkdownSenderResolveTests: XCTestCase {

    /// Build a fake batch of messages with N total messages drawn from a pool of
    /// `uniqueSenders` distinct user_ids (each id appears ~equally).
    private func batch(count: Int, uniqueSenders: [Int64]) -> [[String: Any]] {
        (0..<count).map { i in
            let senderId = uniqueSenders[i % uniqueSenders.count]
            return [
                "id": Int64(i + 1),
                "date": 1_700_000_000 + i,
                "sender": ["type": "user", "user_id": senderId],
                "is_outgoing": false,
                "type": "text",
                "text": "m\(i)",
            ]
        }
    }

    /// Wrap `user_id` and `first_name` / `last_name` into the JSON shape returned by
    /// `TDLibClient.getUser(userId:)`.
    private func userJSON(id: Int64, first: String, last: String = "") -> String {
        let obj: [String: Any] = [
            "id": id,
            "first_name": first,
            "last_name": last,
            "username": "",
            "phone_number": "",
            "is_contact": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Batch cache: one lookup per unique sender

    func testExactlyOneLookupPerUniqueSender() async {
        let messages = batch(count: 1000, uniqueSenders: [10, 20, 30])
        actor LookupCounter {
            var calls: [Int64: Int] = [:]
            func record(_ id: Int64) { calls[id, default: 0] += 1 }
            func snapshot() -> [Int64: Int] { calls }
        }
        let counter = LookupCounter()

        let names = await resolveSenderNames(in: messages) { uid in
            await counter.record(uid)
            return self.userJSON(id: uid, first: "User\(uid)")
        }

        let calls = await counter.snapshot()
        XCTAssertEqual(calls, [10: 1, 20: 1, 30: 1],
                       "Each unique sender MUST be looked up exactly once across 1000 messages")
        XCTAssertEqual(names.count, 3, "Name cache MUST contain one entry per unique sender")
    }

    // MARK: - Lookup failure: fallback to `User <id>`

    func testFallbackWhenLookupThrows() async {
        let messages = batch(count: 10, uniqueSenders: [999])
        struct Boom: Error {}

        let names = await resolveSenderNames(in: messages) { _ in
            throw Boom()
        }

        XCTAssertEqual(names[999], "User 999",
                       "Lookup failure MUST fall back to `User <id>` format")
    }

    /// The dump operation MUST NOT abort because of an individual `getUser` failure.
    /// We prove this by mixing a failing and a succeeding id and verifying both entries
    /// end up in the cache.
    func testMixedLookupOutcomesDoNotAbortOperation() async {
        let messages = batch(count: 20, uniqueSenders: [10, 20])
        struct Boom: Error {}

        let names = await resolveSenderNames(in: messages) { uid in
            if uid == 10 { throw Boom() }
            return self.userJSON(id: uid, first: "Twenty")
        }

        XCTAssertEqual(names[10], "User 10",
                       "Failing sender MUST fall back without aborting")
        XCTAssertEqual(names[20], "Twenty",
                       "Successful sender MUST resolve normally alongside failing sender")
    }

    // MARK: - Name composition

    func testFirstNameAndLastNameCombinedWithSpace() async {
        let messages: [[String: Any]] = [[
            "sender": ["type": "user", "user_id": 42],
            "id": Int64(1), "date": 1_700_000_000, "is_outgoing": false,
            "type": "text", "text": "hi",
        ]]
        let names = await resolveSenderNames(in: messages) { uid in
            self.userJSON(id: uid, first: "培鈞", last: "徐")
        }
        XCTAssertEqual(names[42], "培鈞 徐",
                       "first_name + last_name MUST be combined with single space")
    }

    func testEmptyNameFieldsFallToUserIdFormat() async {
        let messages: [[String: Any]] = [[
            "sender": ["type": "user", "user_id": 42],
            "id": Int64(1), "date": 1_700_000_000, "is_outgoing": false,
            "type": "text", "text": "hi",
        ]]
        let names = await resolveSenderNames(in: messages) { uid in
            self.userJSON(id: uid, first: "", last: "")
        }
        XCTAssertEqual(names[42], "User 42",
                       "Empty first_name AND last_name MUST fall back to `User <id>`")
    }
}
