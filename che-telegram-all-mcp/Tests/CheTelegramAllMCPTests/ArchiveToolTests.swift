import Darwin
import MCP
import XCTest
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// `archive_chat_to_markdown` / `download_message_media` arguments and the local-cache archive
/// path (PsychQuant/che-msg#69). Synthetic messages only; TDLib is held by a fake process so no
/// TDLib client is ever created.
final class ArchiveToolTests: XCTestCase {
    /// Pages like LocalTDLibReader (newest first, inclusive cursor, no file info).
    private final class PagingReader: LocalCacheReading {
        var messages: [[String: Any]] = []
        var historyCalls = 0
        func getChatHistory(chatId: Int64, limit: Int, fromMessageId: Int64, maxMessages: Int?,
                            sinceDate: Date?, untilDate: Date?) throws -> LocalTDLibReader.Result {
            historyCalls += 1
            let upTo = fromMessageId == 0 ? Int64.max : fromMessageId
            let page = messages.filter { (($0["id"] as? NSNumber)?.int64Value ?? 0) <= upTo }.prefix(limit)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: Array(page)), as: UTF8.self)
            return .init(json: json, undecodableCount: 0, freshness: [.init(chatId: chatId, newest: .date(1_791_676_800))])
        }
        func getChats(limit: Int) throws -> LocalTDLibReader.Result { throw LocalReaderError.keyNotFound }
        func searchChats(query: String, limit: Int) throws -> LocalTDLibReader.Result { throw LocalReaderError.keyNotFound }
        func searchMessages(chatId: Int64, query: String, limit: Int) throws -> LocalTDLibReader.Result {
            throw LocalReaderError.keyNotFound
        }
        func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int, sinceDate: Date?,
                                untilDate: Date?, selfLabel: String) async throws -> LocalTDLibReader.Result {
            throw LocalReaderError.keyNotFound
        }
    }

    private var cache: URL!
    private var out: URL!
    private let reader = PagingReader()

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tool-\(UUID().uuidString)")
        cache = root.appendingPathComponent("tdlib")
        out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func holdTDLib(asPid pid: Int32) throws {
        let fd = open(cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { close(fd) }
        try "\(pid)\n".write(to: cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner"), atomically: true, encoding: .utf8)
    }

    private var server: CheTelegramAllMCPServer?

    /// Calls the tool on one server per test, with TDLib held (once) by process 4242.
    private func archive(_ args: [String: Value]) async throws -> CallTool.Result {
        if server == nil {
            try holdTDLib(asPid: 4242)
            server = try await CheTelegramAllMCPServer(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                                                       idleTimeout: 600, reader: reader)
        }
        let server = try XCTUnwrap(server)
        let result = await server.handleToolCall(name: "archive_chat_to_markdown", arguments: args)
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen, "no TDLib client may be created while another process holds TDLib")
        return result
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }
    }

    /// A local-reader message at `unix` seconds from user 1001.
    private func message(_ id: Int64, at unix: Int, type: String = "text") -> [String: Any] {
        ["id": NSNumber(value: id), "chat_id": NSNumber(value: 777), "date": NSNumber(value: unix), "type": type,
         "text": "synthetic \(id)", "is_outgoing": false, "sender": ["type": "user", "user_id": NSNumber(value: 1001)]]
    }

    private func assertRefused(_ args: [String: Value], naming argument: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await archive(args)
        XCTAssertEqual(result.isError, true, file: file, line: line)
        XCTAssertTrue(texts(result).joined().contains(argument), "\(texts(result))", file: file, line: line)
        XCTAssertEqual(reader.historyCalls, 0, "nothing is read for an invalid call", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no file is written", file: file, line: line)
    }

    // MARK: - Archive tool parameters

    // Scenario "Relative output directory is refused".
    func testRelativeOutputDirIsRefused() async throws {
        try await assertRefused(["chat_id": .int(777), "output_dir": .string("archives/telegram")], naming: "output_dir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "archives/telegram"))
    }

    func testMalformedArgumentsAreRefused() async throws {
        let base: [String: Value] = ["chat_id": .int(777), "output_dir": .string(out.path)]
        let cases: [(String, Value)] = [
            ("utc_offset", .string("+8")), ("utc_offset", .string("+-1:00")), ("utc_offset", .int(8)),
            ("utc_offset", .string("+19:00")),
            ("since_date", .string("2026-02-30")), ("since_date", .string("2026/01/01")), ("since_date", .int(20260101)),
            ("after_message_id", .int(-1)), ("after_message_id", .string("x")),
            ("max_media_bytes", .int(-1)), ("max_media_bytes", .string("big")),
            ("retry_media_message_ids", .array([.string("abc")])), ("retry_media_message_ids", .array([.double(1.5)])),
            ("retry_media_message_ids", .array([.int(0)])), ("retry_media_message_ids", .int(7100)),
        ]
        for (key, value) in cases {
            var args = base
            args[key] = value
            try await assertRefused(args, naming: key)
        }
        try await assertRefused(["output_dir": .string(out.path)], naming: "chat_id")
        try await assertRefused(["chat_id": .int(777)], naming: "output_dir")
    }

    // Scenario "Bookmark takes precedence over a start date".
    func testBookmarkTakesPrecedenceOverStartDate() async throws {
        reader.messages = [message(9100, at: 1_748_736_000),   // 2025-06-01, before since_date
                           message(8900, at: 1_780_272_000)]   // 2026-06-01, at or below the bookmark
        let result = try await archive(["chat_id": .int(777), "output_dir": .string(out.path),
                                        "after_message_id": .int(9000), "since_date": .string("2026-01-01"),
                                        "utc_offset": .string("+08:00")])
        XCTAssertEqual(result.isError, false, "\(texts(result))")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((texts(result).first ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(manifest["new_messages"] as? Int, 1)
        XCTAssertEqual(manifest["newest_message_id"] as? Int, 9100)
        XCTAssertEqual(manifest["files"] as? [String], ["777/2025-06-01.md"])
    }

    func testAbsentOffsetIsTheServersOffsetAndSinceUsesIt() throws {
        let taipei = try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))
        let request = try parseArchiveChatArgs(["chat_id": .int(777), "output_dir": .string("/tmp/a"),
                                                "since_date": .string("2026-01-01")],
                                               now: Date(timeIntervalSince1970: 1_791_676_800), timeZone: taipei)
        XCTAssertEqual(request.utcOffset, "+08:00")
        XCTAssertEqual(request.since, Date(timeIntervalSince1970: 1_767_196_800))   // 2026-01-01 00:00 +08:00
        XCTAssertEqual(request.outputDir.path, "/tmp/a")
        XCTAssertNil(request.afterMessageId)
        let explicit = try parseArchiveChatArgs(["chat_id": .int(777), "output_dir": .string("/tmp/a"),
                                                 "utc_offset": .string("-03:30"), "max_media_bytes": .int(10_000_000),
                                                 "retry_media_message_ids": .array([.int(7100), .string("7300")])],
                                                timeZone: taipei)
        XCTAssertEqual(explicit.utcOffset, "-03:30")
        XCTAssertEqual(explicit.maxMediaBytes, 10_000_000)
        XCTAssertEqual(explicit.retryMediaMessageIds, [7100, 7300])
    }

    // MARK: - Archive from the local cache

    // Scenario "Another session holds TDLib".
    func testLocalCacheArchiveWritesFilesAndAMarkedManifest() async throws {
        reader.messages = [message(30, at: 1_791_677_000, type: "photo"), message(20, at: 1_791_676_900)]
        let result = try await archive(["chat_id": .int(777), "output_dir": .string(out.path),
                                        "utc_offset": .string("+08:00")])
        XCTAssertEqual(result.isError, false, "\(texts(result))")
        let items = texts(result)
        XCTAssertEqual(items.count, 2)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(items[0].utf8)) as? [String: Any])
        XCTAssertEqual(manifest["source"] as? String, "local-cache")
        XCTAssertEqual(manifest["bookmark_safe"] as? Bool, false)
        XCTAssertEqual(manifest["bookmark_unsafe_reason"] as? String, "local-cache")
        XCTAssertEqual(manifest["complete"] as? Bool, true)
        XCTAssertEqual(manifest["media_pending_local_cache"] as? Int, 1)
        XCTAssertEqual(manifest["media_downloaded"] as? Int, 0)
        XCTAssertFalse(items[0].contains("synthetic"), "the manifest carries no message text")
        XCTAssertTrue(items[1].contains("source: local-cache"))
        XCTAssertTrue(items[1].contains("4242"))
        let day = try String(contentsOf: out.appendingPathComponent("777/2026-10-11.md"), encoding: .utf8)
        XCTAssertTrue(day.contains("User 1001"), day)
        XCTAssertTrue(day.contains("[photo](media/30/)"), day)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("777/media").path))
    }

    // MARK: - download_message_media

    func testDownloadArguments() throws {
        let ok = try parseDownloadMediaArgs(["chat_id": .int(777), "message_id": .int(5_243_904),
                                             "output_dir": .string("/tmp/view")])
        XCTAssertEqual(ok, DownloadMediaArgs(chatId: 777, messageId: 5_243_904, outputDir: URL(fileURLWithPath: "/tmp/view")))
        let refusals: [([String: Value], String)] = [
            (["chat_id": .int(777), "message_id": .int(1), "output_dir": .string("view")], "output_dir"),
            (["chat_id": .int(777), "output_dir": .string("/tmp/view")], "message_id"),
            (["chat_id": .int(777), "message_id": .int(0), "output_dir": .string("/tmp/view")], "message_id"),
            (["message_id": .int(1), "output_dir": .string("/tmp/view")], "chat_id"),
        ]
        for (args, name) in refusals {
            XCTAssertThrowsError(try parseDownloadMediaArgs(args)) { error in
                XCTAssertTrue("\(error)".contains(name), "\(error)")
            }
        }
    }

    // Scenario "Text message": the download core's error becomes an isError result.
    func testTextMessageDownloadErrorIsAToolError() {
        let result = errorResultFromParse(ArchiveMedia.DownloadError.noFile(messageId: 1))
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(texts(result).joined().contains("message 1 has no media file"), "\(texts(result))")
    }
}
