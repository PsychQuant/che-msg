import XCTest
@testable import TelegramAllLib

/// Archiving from TDLib's local cache (telegram-chat-archive, "Archive from the local cache";
/// PsychQuant/che-msg#69). Synthetic messages only.
final class LocalCacheArchiveTests: XCTestCase {
    /// Pages like LocalTDLibReader: newest first, strictly below the cursor (`message_id < from`,
    /// as TDLib; #73), messages carry a type but no file or caption.
    final class StrictReader: LocalCacheReading {
        var messages: [[String: Any]]
        var cursors: [Int64] = []
        var limits: [Int] = []
        init(_ messages: [[String: Any]]) { self.messages = messages }
        func getChatHistory(chatId: Int64, limit: Int, fromMessageId: Int64, maxMessages: Int?,
                            sinceDate: Date?, untilDate: Date?) throws -> LocalTDLibReader.Result {
            cursors.append(fromMessageId)
            limits.append(limit)
            let below = fromMessageId == 0 ? Int64.max : fromMessageId
            let page = messages.filter { (($0["id"] as? NSNumber)?.int64Value ?? 0) < below }.prefix(limit)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: Array(page)), as: UTF8.self)
            return .init(json: json, undecodableCount: 1,
                         freshness: [.init(chatId: chatId, newest: .date(1_791_676_800))])
        }
        func getChats(limit: Int) throws -> LocalTDLibReader.Result { throw LocalReaderError.keyNotFound }
        func searchChats(query: String, limit: Int) throws -> LocalTDLibReader.Result { throw LocalReaderError.keyNotFound }
        func searchMessages(chatId: Int64, query: String, limit: Int) throws -> LocalTDLibReader.Result {
            throw LocalReaderError.keyNotFound
        }
        func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int, sinceDate: Date?,
                                untilDate: Date?, selfLabel: String, exportRoot: String?) async throws -> LocalTDLibReader.Result {
            throw LocalReaderError.keyNotFound
        }
    }

    private func local(_ id: Int64, _ minutes: Int, type: String = "text") -> [String: Any] {
        var m = ChatArchiverTests.msg(id, minutes, type: type)
        m["file"] = nil
        m["caption"] = nil
        return m
    }

    private func outputDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-archive-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testWholeHistoryFromTheLocalCacheIsComplete() async throws {
        let reader = StrictReader([local(30, 3), local(20, 2, type: "photo"), local(10, 1)])
        let source = LocalCacheHistorySource(reader: reader)
        let archiver = ChatArchiver(source: source, sourceKind: .localCache, isSynced: { false }, pageSize: 2)
        let result = try await archiver.archive(.init(chatId: 777, outputDir: outputDir(), utcOffset: "+08:00"))
        XCTAssertEqual(result.newMessages, 3)
        XCTAssertTrue(result.complete, "a source that pages strictly below the cursor does not read as stuck")
        XCTAssertEqual(Set(reader.limits), [2], "every page asks for the page size, no extra row for the cursor (#73)")
        XCTAssertNil(result.stoppedReason)
        XCTAssertEqual(result.source, .localCache)
        XCTAssertFalse(result.bookmarkSafe)
        XCTAssertEqual(result.bookmarkUnsafeReason, "local-cache")
        XCTAssertEqual(result.mediaPendingLocalCache, 1)
        XCTAssertEqual(source.freshness.map(\.chatId), [777])
        XCTAssertGreaterThan(source.undecodableCount, 0)
    }

    func testFactoryArchivesWithoutNamesOrDownloads() async throws {
        let reader = StrictReader([local(30, 3), local(20, 2)])
        let dir = outputDir()
        let result = try await ChatArchiver.localCache(LocalCacheHistorySource(reader: reader))
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertTrue(result.complete)
        let text = try String(contentsOf: dir.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("**08:03 User 1001**："), text)
    }

    // Scenario "Poll archived from the local cache" (#82): the reader gives a poll's type only.
    func testAPollFromTheLocalCacheIsTheBareLabel() async throws {
        let reader = StrictReader([local(30, 3, type: "poll"), local(20, 2, type: "location")])
        let dir = outputDir()
        _ = try await ChatArchiver.localCache(LocalCacheHistorySource(reader: reader))
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        let text = try String(contentsOf: dir.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("**08:03 User 1001**：\n[poll]\n\n"), text)
        XCTAssertTrue(text.contains("**08:02 User 1001**：\n[location]\n\n"), text)
    }

    // Scenario "Cache record without a date" (#75): not written (its day is unknown), but counted.
    func testUndatedCacheRecordIsCountedAndNotWritten() async throws {
        var undated = local(20, 2)
        undated["date"] = nil
        let reader = StrictReader([local(30, 3), undated])
        let dir = outputDir()
        let result = try await ChatArchiver.localCache(LocalCacheHistorySource(reader: reader))
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
        XCTAssertEqual(result.newMessages, 1)
        XCTAssertEqual(result.undatedMessagesSkipped, 1)
        XCTAssertFalse(result.bookmarkSafe, "a later TDLib run of the same range adds it")
        let text = try String(contentsOf: dir.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(text).map(\.id), [30])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.manifestJSON().utf8)) as? [String: Any])
        XCTAssertEqual(object["undated_messages_skipped"] as? Int, 1)
    }
}
