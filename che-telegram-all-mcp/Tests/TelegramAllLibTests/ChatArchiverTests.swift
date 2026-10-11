import XCTest
@testable import TelegramAllLib

/// telegram-chat-archive (PsychQuant/che-msg#69, tasks 2.1–2.3). Synthetic messages only.
final class ChatArchiverTests: XCTestCase {
    /// History held newest first; pages are the messages below `fromMessageId`.
    final class FakeSource: ArchiveHistorySource, @unchecked Sendable {
        var messages: [[String: Any]]          // newest first
        var failures: [Error] = []             // thrown by the next calls, in order
        var calls = 0
        init(_ messages: [[String: Any]]) { self.messages = messages }
        func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
            calls += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            let below = messages.filter { fromMessageId == 0 || (($0["id"] as! NSNumber).int64Value) < fromMessageId }
            return Array(below.prefix(limit))
        }
    }

    /// Message `id` sent `minutesAfter` 2026-10-11 00:00 UTC (08:00 at +08:00).
    static func msg(_ id: Int64, _ minutesAfter: Int, type: String = "text", text: String? = nil,
                    caption: String? = nil, from user: Int64 = 1001, outgoing: Bool = false) -> [String: Any] {
        var m: [String: Any] = ["id": NSNumber(value: id), "chat_id": NSNumber(value: 777),
                                "date": NSNumber(value: 1_791_676_800 + minutesAfter * 60),
                                "sender": ["type": "user", "user_id": NSNumber(value: user)],
                                "is_outgoing": outgoing, "type": type]
        if type == "text" { m["text"] = text ?? "m\(id)" }
        if let caption { m["caption"] = caption }
        return m
    }

    private func outputDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archiver-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func archiver(_ source: FakeSource, kind: ChatArchiver.Source = .tdlib, synced: Bool = true,
                          pageSize: Int = 2) -> ChatArchiver {
        ChatArchiver(source: source, sourceKind: kind, resolveNames: nil, isSynced: { synced }, pageSize: pageSize)
    }

    private func ids(in dir: URL, _ relative: String) throws -> [Int64] {
        let text = try String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8)
        return ArchiveDayFile.parseBlocks(text).map(\.id)
    }

    // Scenario "Incremental run": only messages above the bookmark.
    func testOnlyMessagesAboveTheBookmarkAreArchived() async throws {
        let dir = try outputDir()
        let source = FakeSource([Self.msg(5_245_952, 30), Self.msg(5_244_928, 20), Self.msg(5_243_904, 10), Self.msg(5_242_880, 5)])
        let result = try await archiver(source).archive(.init(chatId: 777, outputDir: dir, afterMessageId: 5_243_904,
                                                              utcOffset: "+08:00"))
        XCTAssertEqual(try ids(in: dir, "777/2026-10-11.md"), [5_244_928, 5_245_952])
        XCTAssertEqual(result.newMessages, 2)
        XCTAssertEqual(result.newestMessageId, 5_245_952)
        XCTAssertEqual(result.files, ["777/2026-10-11.md"])
    }

    func testSinceDateIsTheLowerBoundWithoutABookmark() async throws {
        let dir = try outputDir()
        // 2026-10-10 23:50 UTC (07:50 on the 11th at +08:00) is before a since of the 11th at 08:00? No:
        // since = start of 2026-10-11 at +08:00 = 2026-10-10 16:00 UTC.
        let since = Date(timeIntervalSince1970: 1_791_648_000)   // 2026-10-10 16:00:00 UTC
        let source = FakeSource([Self.msg(30, 10), Self.msg(20, -480), Self.msg(10, -481)])
        // minute -480 = 2026-10-10 16:00 UTC (kept, on the bound); -481 = 15:59 UTC (dropped)
        let result = try await archiver(source).archive(.init(chatId: 777, outputDir: dir, since: since, utcOffset: "+08:00"))
        XCTAssertEqual(try ids(in: dir, "777/2026-10-11.md"), [20, 30])
        XCTAssertEqual(result.newMessages, 2)
    }

    func testWholeHistoryWithoutBoundsAcrossDays() async throws {
        let dir = try outputDir()
        // 3 messages: one on 2026-10-10 local (+08:00), two on 2026-10-11.
        let source = FakeSource([Self.msg(30, 60), Self.msg(20, 0), Self.msg(10, -481)])
        let result = try await archiver(source).archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertEqual(result.files.sorted(), ["777/2026-10-10.md", "777/2026-10-11.md"])
        XCTAssertEqual(try ids(in: dir, "777/2026-10-10.md"), [10])
        XCTAssertEqual(try ids(in: dir, "777/2026-10-11.md"), [20, 30])
        XCTAssertEqual(result.newMessages, 3)
    }

    func testMediaCaptionAndSenderLabels() async throws {
        let dir = try outputDir()
        let source = FakeSource([Self.msg(40, 2, type: "photo", caption: "menu", outgoing: true),
                                 Self.msg(30, 1, from: 2002)])
        let archiver = ChatArchiver(source: source, sourceKind: .tdlib,
                                    resolveNames: { _ in [2002: "Alex"] }, isSynced: { true }, pageSize: 10)
        let result = try await archiver.archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        let text = try String(contentsOf: dir.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("**08:01 Alex**：\nm30\n"), text)
        XCTAssertTrue(text.contains("**08:02 我**：\n[photo](media/40/) menu\n"), text)
        XCTAssertEqual(result.mediaMessages, 1)
    }

    func testUnresolvedSendersFallBackToUserId() async throws {
        let dir = try outputDir()
        let result = try await archiver(FakeSource([Self.msg(30, 1, from: 2002)]))
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        let text = try String(contentsOf: dir.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("**08:01 User 2002**："), text)
        XCTAssertEqual(result.newMessages, 1)
    }

    /// A source whose pages repeat the boundary message must not loop forever.
    func testRepeatingPagesTerminate() async throws {
        final class Repeating: ArchiveHistorySource {
            var calls = 0
            func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
                calls += 1
                return [ChatArchiverTests.msg(30, 1)]
            }
        }
        let dir = try outputDir()
        let source = Repeating()
        let archiver = ChatArchiver(source: source, sourceKind: .tdlib, isSynced: { true }, pageSize: 1)
        let result = try await archiver.archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertLessThanOrEqual(source.calls, 3)
        XCTAssertEqual(result.newMessages, 1)
    }

    // MARK: - Manifest and bookmark safety (task 2.2)

    // Example "bookmark safety table", row by row.
    func testBookmarkSafetyTable() async throws {
        struct Row { let reachedBound: Bool; let kind: ChatArchiver.Source; let synced: Bool
                     let safe: Bool; let reason: String? }
        let rows = [
            Row(reachedBound: true, kind: .tdlib, synced: true, safe: true, reason: nil),
            Row(reachedBound: false, kind: .tdlib, synced: true, safe: false, reason: "incomplete"),
            Row(reachedBound: true, kind: .tdlib, synced: false, safe: false, reason: "not-synced"),
            Row(reachedBound: true, kind: .localCache, synced: true, safe: false, reason: "local-cache"),
        ]
        for (n, row) in rows.enumerated() {
            let dir = try outputDir()
            let source = FakeSource([Self.msg(30, 2), Self.msg(20, 1), Self.msg(10, 0)])
            // Not reaching the bound: a page that repeats stops paging before the bound.
            if !row.reachedBound { source.failures = [] }
            let archiver = row.reachedBound
                ? ChatArchiver(source: source, sourceKind: row.kind, isSynced: { row.synced }, pageSize: 10)
                : ChatArchiver(source: StuckSource(), sourceKind: row.kind, isSynced: { row.synced }, pageSize: 1)
            let result = try await archiver.archive(.init(chatId: 777, outputDir: dir, afterMessageId: 5, utcOffset: "+08:00"))
            XCTAssertEqual(result.bookmarkSafe, row.safe, "row \(n)")
            XCTAssertEqual(result.bookmarkUnsafeReason, row.reason, "row \(n)")
            XCTAssertEqual(result.source, row.kind, "row \(n)")
        }
    }

    /// Returns the same message forever: paging stops without reaching the bound.
    final class StuckSource: ArchiveHistorySource {
        func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
            [ChatArchiverTests.msg(30, 1)]
        }
    }

    func testCompleteRunIsMarkedComplete() async throws {
        let result = try await archiver(FakeSource([Self.msg(30, 1)])).archive(
            .init(chatId: 777, outputDir: try outputDir(), utcOffset: "+08:00"))
        XCTAssertTrue(result.complete)
        XCTAssertNil(result.stoppedReason)
    }

    // Requirement "Content-free manifest": JSON shape, and no text, caption or sender name.
    func testManifestJSONHasTheFieldsAndNoContent() async throws {
        let source = FakeSource([Self.msg(40, 2, type: "photo", caption: "secret caption"),
                                 Self.msg(30, 1, text: "secret text", from: 2002)])
        let archiver = ChatArchiver(source: source, sourceKind: .tdlib, resolveNames: { _ in [2002: "Secret Name"] },
                                    isSynced: { true }, pageSize: 10)
        let result = try await archiver.archive(.init(chatId: 777, outputDir: try outputDir(), utcOffset: "+08:00"))
        let json = result.manifestJSON()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["files"] as? [String], ["777/2026-10-11.md"])
        XCTAssertEqual(object["new_messages"] as? Int, 2)
        XCTAssertEqual(object["media_messages"] as? Int, 1)
        XCTAssertEqual((object["newest_message_id"] as? NSNumber)?.int64Value, 40)
        XCTAssertEqual(object["source"] as? String, "tdlib")
        XCTAssertEqual(object["complete"] as? Bool, true)
        XCTAssertEqual(object["bookmark_safe"] as? Bool, true)
        XCTAssertNil(object["bookmark_unsafe_reason"])
        for secret in ["secret caption", "secret text", "Secret Name"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
    }

    func testNewestMessageIdIsNullWhenNothingIsInBound() async throws {
        let result = try await archiver(FakeSource([Self.msg(30, 1)])).archive(
            .init(chatId: 777, outputDir: try outputDir(), afterMessageId: 30, utcOffset: "+08:00"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.manifestJSON().utf8)) as? [String: Any])
        XCTAssertTrue(object["newest_message_id"] is NSNull)
        XCTAssertEqual(object["files"] as? [String], [])
        XCTAssertEqual(result.bookmarkSafe, true)
    }

    // MARK: - Rate limits (task 2.3)

    private final class Sleeps: @unchecked Sendable { var seconds: [Int] = [] }

    private func flood(_ n: Int) -> Error { TDLibClient.TDError.tdlibError(code: 420, message: "FLOOD_WAIT_\(n)") }

    func testShortFloodWaitIsRetriedOnce() async throws {
        let dir = try outputDir()
        let source = FakeSource([Self.msg(30, 2), Self.msg(20, 1)])
        source.failures = [flood(30)]
        let sleeps = Sleeps()
        let archiver = ChatArchiver(source: source, sourceKind: .tdlib, isSynced: { true }, pageSize: 10,
                                    sleep: { sleeps.seconds.append($0) })
        let result = try await archiver.archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertEqual(sleeps.seconds, [30])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.newMessages, 2)
        XCTAssertTrue(result.bookmarkSafe)
    }

    // Scenario "Long rate limit": stop, keep what was written.
    func testLongFloodWaitStopsAndKeepsWrittenFiles() async throws {
        let dir = try outputDir()
        let source = FakeSource([Self.msg(30, 2), Self.msg(20, 1), Self.msg(10, 0)])
        let sleeps = Sleeps()
        // First page succeeds, the second fails with a long wait.
        final class FailSecond: ArchiveHistorySource {
            let inner: FakeSource; let error: Error; var calls = 0
            init(_ inner: FakeSource, _ error: Error) { self.inner = inner; self.error = error }
            func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
                calls += 1
                if calls == 2 { throw error }
                return try await inner.page(chatId: chatId, fromMessageId: fromMessageId, limit: limit)
            }
        }
        let failing = ChatArchiver(source: FailSecond(source, flood(420)), sourceKind: .tdlib, isSynced: { true },
                                   pageSize: 1, sleep: { sleeps.seconds.append($0) })
        let result = try await failing.archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertEqual(sleeps.seconds, [])
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.stoppedReason, "flood_wait")
        XCTAssertEqual(result.retryAfterSeconds, 420)
        XCTAssertFalse(result.bookmarkSafe)
        XCTAssertEqual(result.bookmarkUnsafeReason, "incomplete")
        XCTAssertEqual(try ids(in: dir, "777/2026-10-11.md"), [30])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.manifestJSON().utf8)) as? [String: Any])
        XCTAssertEqual(object["stopped_reason"] as? String, "flood_wait")
        XCTAssertEqual(object["retry_after_seconds"] as? Int, 420)
    }

    func testShortFloodWaitThatRepeatsStops() async throws {
        let source = FakeSource([Self.msg(30, 2)])
        source.failures = [flood(5), flood(7)]
        let sleeps = Sleeps()
        let archiver = ChatArchiver(source: source, sourceKind: .tdlib, isSynced: { true }, pageSize: 10,
                                    sleep: { sleeps.seconds.append($0) })
        let result = try await archiver.archive(.init(chatId: 777, outputDir: try outputDir(), utcOffset: "+08:00"))
        XCTAssertEqual(sleeps.seconds, [5])
        XCTAssertEqual(result.stoppedReason, "flood_wait")
        XCTAssertEqual(result.retryAfterSeconds, 7)
    }

    func testOtherErrorsAreThrown() async throws {
        let source = FakeSource([Self.msg(30, 2)])
        source.failures = [TDLibClient.TDError.tdlibError(code: 400, message: "CHAT_ID_INVALID")]
        do {
            _ = try await archiver(source).archive(.init(chatId: 777, outputDir: try outputDir(), utcOffset: "+08:00"))
            XCTFail("expected the error to be thrown")
        } catch TDLibClient.TDError.tdlibError(let code, _) {
            XCTAssertEqual(code, 400)
        }
    }
}
