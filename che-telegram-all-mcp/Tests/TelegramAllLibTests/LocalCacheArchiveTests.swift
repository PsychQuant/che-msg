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

    // MARK: - Provisional blocks and their upgrade (#72)

    private let marker = "<!-- provisional: local-cache -->"

    private func cacheArchive(_ messages: [[String: Any]], into dir: URL) async throws -> ChatArchiver.Result {
        try await ChatArchiver.localCache(LocalCacheHistorySource(reader: StrictReader(messages)))
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
    }

    private func tdlibArchive(_ messages: [[String: Any]], into dir: URL) async throws -> ChatArchiver.Result {
        try await ChatArchiver(source: ChatArchiverTests.FakeSource(messages), sourceKind: .tdlib,
                               resolveNames: { _ in [1001: "Alex"] }, isSynced: { true }, pageSize: 10)
            .archive(.init(chatId: 777, outputDir: dir, utcOffset: "+08:00"))
    }

    private func dayFile(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
    }

    // Scenario "Another session holds TDLib": every block the cache call adds is provisional.
    func testEveryBlockFromTheLocalCacheIsProvisional() async throws {
        let dir = outputDir()
        let result = try await cacheArchive([local(30, 3), local(20, 2, type: "photo")], into: dir)
        XCTAssertEqual(result.newMessages, 2)
        XCTAssertEqual(result.upgradedMessages, 0)
        let text = try dayFile(dir)
        XCTAssertTrue(text.contains("<!-- msg:20 -->\n\(marker)\n**08:02 User 1001**：\n[photo](media/20/)\n\n"), text)
        XCTAssertTrue(text.contains("<!-- msg:30 -->\n\(marker)\n**08:03 User 1001**：\nm30\n\n"), text)
    }

    // Scenario "TDLib run after a cache run".
    func testATDLibRunUpgradesTheBlocksACacheRunWrote() async throws {
        let dir = outputDir()
        _ = try await cacheArchive([local(30, 3, type: "photo"), local(20, 2)], into: dir)
        // A block the cache did not write stays as it is.
        let tdlibOnly = "<!-- msg:10 -->\n**08:01 Someone**：\nkept\n\n"
        let file = dir.appendingPathComponent("777/2026-10-11.md")
        let cached = try dayFile(dir)
        let withPlain = cached.replacingOccurrences(of: "<!-- msg:20 -->", with: tdlibOnly + "<!-- msg:20 -->")
        try Data(withPlain.utf8).write(to: file)

        let result = try await tdlibArchive([ChatArchiverTests.msg(30, 3, type: "photo", caption: "menu"),
                                             ChatArchiverTests.msg(20, 2), ChatArchiverTests.msg(10, 1)], into: dir)
        XCTAssertEqual(result.upgradedMessages, 2)
        XCTAssertEqual(result.newMessages, 0)
        XCTAssertEqual(result.mediaMessages, 0, "an upgrade is not a new message")
        XCTAssertEqual(result.files, ["777/2026-10-11.md"])
        let text = try dayFile(dir)
        XCTAssertFalse(text.contains(marker), text)
        XCTAssertTrue(text.contains(tdlibOnly), text)
        XCTAssertTrue(text.contains("<!-- msg:20 -->\n**08:02 Alex**：\nm20\n\n"), text)
        XCTAssertTrue(text.contains("<!-- msg:30 -->\n**08:03 Alex**：\n[photo](media/30/) menu\n\n"), text)
        XCTAssertEqual(ArchiveDayFile.parseBlocks(text).map(\.id), [10, 20, 30])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.manifestJSON().utf8)) as? [String: Any])
        XCTAssertEqual(object["upgraded_messages"] as? Int, 2)

        // Scenario "TDLib re-run after an upgrade".
        let before = try Data(contentsOf: file)
        let again = try await tdlibArchive([ChatArchiverTests.msg(30, 3, type: "photo", caption: "menu"),
                                            ChatArchiverTests.msg(20, 2), ChatArchiverTests.msg(10, 1)], into: dir)
        XCTAssertEqual(again.upgradedMessages, 0)
        XCTAssertEqual(again.files, [])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    // Scenario "Cache run after a TDLib run": no downgrade.
    func testACacheRunNeverReplacesABlock() async throws {
        let dir = outputDir()
        _ = try await tdlibArchive([ChatArchiverTests.msg(30, 3), ChatArchiverTests.msg(20, 2)], into: dir)
        let file = dir.appendingPathComponent("777/2026-10-11.md")
        let before = try Data(contentsOf: file)
        let result = try await cacheArchive([local(30, 3), local(20, 2)], into: dir)
        XCTAssertEqual(result.upgradedMessages, 0)
        XCTAssertEqual(result.newMessages, 0)
        XCTAssertEqual(result.files, [])
        XCTAssertEqual(try Data(contentsOf: file), before)
        // And a second cache run over its own blocks changes nothing either.
        let cacheDir = outputDir()
        _ = try await cacheArchive([local(30, 3)], into: cacheDir)
        let cached = try Data(contentsOf: cacheDir.appendingPathComponent("777/2026-10-11.md"))
        _ = try await cacheArchive([local(30, 3)], into: cacheDir)
        XCTAssertEqual(try Data(contentsOf: cacheDir.appendingPathComponent("777/2026-10-11.md")), cached)
    }
}
