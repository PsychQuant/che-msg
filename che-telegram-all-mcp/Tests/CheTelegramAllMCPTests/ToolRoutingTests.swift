import Darwin
import MCP
import XCTest
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// Covers "Tool routing while TDLib is held by another process"
/// (telegram-tdlib-lifecycle) and "Reader marks its results as coming from the
/// local cache" (telegram-local-reader); PsychQuant/che-msg#58, task 4.3.
///
/// Another process is played by a second open file description holding the
/// flock in a private cache directory, with PID 4242 recorded as its owner.
final class ToolRoutingTests: XCTestCase {
    private final class FakeReader: LocalCacheReading {
        var calls: [String] = []
        /// The `exportRoot` each `dump_chat_to_markdown` call received (#21).
        var dumpExportRoots: [String?] = []
        var error: Error?
        var result = LocalTDLibReader.Result(
            json: #"[{"id":777}]"#, undecodableCount: 1,
            freshness: [.init(chatId: 777, newest: .date(1_777_507_200)), .init(chatId: 888, newest: .noMessages)])

        private func answer(_ call: String) throws -> LocalTDLibReader.Result {
            calls.append(call)
            if let error { throw error }
            return result
        }

        func getChats(limit: Int) throws -> LocalTDLibReader.Result { try answer("get_chats") }
        func searchChats(query: String, limit: Int) throws -> LocalTDLibReader.Result { try answer("search_chats") }
        func getChatHistory(chatId: Int64, limit: Int, fromMessageId: Int64, maxMessages: Int?,
                            sinceDate: Date?, untilDate: Date?) throws -> LocalTDLibReader.Result { try answer("get_chat_history") }
        func searchMessages(chatId: Int64, query: String, limit: Int) throws -> LocalTDLibReader.Result { try answer("search_messages") }
        func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int, sinceDate: Date?,
                                untilDate: Date?, selfLabel: String, exportRoot: String?) async throws -> LocalTDLibReader.Result {
            dumpExportRoots.append(exportRoot)
            return try answer("dump_chat_to_markdown")
        }
    }

    private static let readerTools = ["get_chats", "search_chats", "get_chat_history", "search_messages", "dump_chat_to_markdown"]
    private static let unsupportedTools = ["get_me", "get_user", "get_contacts", "get_chat", "get_chat_members"]
    /// Answered from the local cache too, but with a manifest rather than the reader's JSON (#69).
    private static let archiveTool = "archive_chat_to_markdown"

    private var cache: URL!
    private let reader = FakeReader()

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    /// Holds the TDLib flock as another process would, recording `pid` as owner.
    private func holdTDLib(asPid pid: Int32?) throws {
        let fd = open(cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { close(fd) }
        if let pid {
            try "\(pid)\n".write(to: cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner"), atomically: true, encoding: .utf8)
        }
    }

    private func makeServer(reader: LocalCacheReading? = nil, exportRoot: String? = nil) async throws -> CheTelegramAllMCPServer {
        try await CheTelegramAllMCPServer(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                                          idleTimeout: 600, reader: reader ?? self.reader, exportRoot: exportRoot)
    }

    /// Arguments that pass each tool's argument checks.
    private func arguments(for tool: String) -> [String: Value] {
        switch tool {
        case "search_chats": return ["query": .string("a")]
        case "get_chat_history", "get_chat", "get_chat_members": return ["chat_id": .int(777)]
        case "search_messages": return ["chat_id": .int(777), "query": .string("a")]
        case "dump_chat_to_markdown":
            return ["chat_id": .int(777), "output_path": .string(cache.appendingPathComponent("chat.md").path)]
        case "get_user": return ["user_id": .int(1001)]
        default: return [:]
        }
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }
    }

    private func json(_ result: CallTool.Result) throws -> [String: Any] {
        let items = texts(result)
        XCTAssertEqual(items.count, 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data((items.first ?? "").utf8)) as? [String: Any])
    }

    // MARK: - Routing table

    /// Scenario "Supported read tool while TDLib is held elsewhere".
    func testReaderToolsAreAnsweredFromTheLocalCache() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        for tool in Self.readerTools {
            let result = await server.handleToolCall(name: tool, arguments: arguments(for: tool))
            XCTAssertEqual(result.isError, false, tool)
            let items = texts(result)
            XCTAssertEqual(items.count, 2, tool)
            XCTAssertEqual(items.first, #"[{"id":777}]"#, tool)
            XCTAssertTrue(items.last?.contains("source: local-cache") == true, tool)
            XCTAssertTrue(items.last?.contains("4242") == true, tool)
            XCTAssertFalse(items.contains { $0.hasPrefix("sync:") }, "local-cache answers carry no sync note (#63): \(tool)")
        }
        XCTAssertEqual(reader.calls, Self.readerTools)
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen, "no TDLib client may be created while another process holds TDLib")
    }

    /// Scenario "Another session holds TDLib" (telegram-chat-archive, #69).
    func testArchiveIsAnsweredFromTheLocalCache() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let result = await server.handleToolCall(name: Self.archiveTool, arguments: [
            "chat_id": .int(777), "output_dir": .string(cache.appendingPathComponent("archive").path),
        ])
        XCTAssertEqual(result.isError, false, "\(texts(result))")
        let items = texts(result)
        XCTAssertEqual(items.count, 2)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((items.first ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(manifest["source"] as? String, "local-cache")
        XCTAssertEqual(manifest["bookmark_safe"] as? Bool, false)
        XCTAssertTrue(items.last?.contains("source: local-cache") == true)
        XCTAssertTrue(items.last?.contains("4242") == true)
        XCTAssertTrue(reader.calls.allSatisfy { $0 == "get_chat_history" } && !reader.calls.isEmpty, "\(reader.calls)")
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen, "no TDLib client may be created while another process holds TDLib")
    }

    /// Scenario "Unsupported read tool while TDLib is held elsewhere".
    func testUnsupportedReadToolsReportLocalReaderUnsupported() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        for tool in Self.unsupportedTools {
            let result = await server.handleToolCall(name: tool, arguments: arguments(for: tool))
            XCTAssertEqual(result.isError, true, tool)
            let payload = try json(result)
            XCTAssertEqual(payload["type"] as? String, "local_reader_unsupported", tool)
            XCTAssertEqual(payload["tool"] as? String, tool)
            XCTAssertNotNil(payload["message"] as? String, tool)
        }
        XCTAssertTrue(reader.calls.isEmpty)
    }

    /// Scenario "Write tool while TDLib is held elsewhere", for every tool the
    /// table does not send to the reader or mark unsupported.
    func testEveryOtherToolReportsTDLibInUse() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let others = CheTelegramAllMCPServer.defineTools().map(\.name)
            .filter { !Self.readerTools.contains($0) && !Self.unsupportedTools.contains($0) && $0 != Self.archiveTool }
        XCTAssertEqual(others.count, 19)
        XCTAssertTrue(others.contains("download_message_media"), "media downloads need TDLib (#69)")
        for tool in others {
            let result = await server.handleToolCall(name: tool, arguments: arguments(for: tool))
            XCTAssertEqual(result.isError, true, tool)
            let payload = try json(result)
            XCTAssertEqual(payload["type"] as? String, "tdlib_in_use", tool)
            XCTAssertEqual((payload["lock_holder_pid"] as? NSNumber)?.int32Value, 4242, tool)
            XCTAssertNotNil(payload["message"] as? String, tool)
        }
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen)
    }

    /// The holder can be a session or a telegram-all command (#61), and a
    /// session may never go idle; the message says how each releases TDLib.
    func testTheInUseMessageSaysHowEachKindOfHolderReleasesTDLib() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let payload = try json(await server.handleToolCall(name: "send_message", arguments: [:]))
        XCTAssertEqual(payload["message"] as? String,
                       "TDLib is in use by another process (PID 4242), so this tool cannot run now. "
                       + "Try again once it has released TDLib: a telegram-all command releases it when it finishes; "
                       + "a Claude Code session using telegram-all releases it when the session ends, and can release "
                       + "it earlier, once it has had no calls for its idle timeout (CHE_TELEGRAM_ALL_IDLE_TIMEOUT, "
                       + "600 seconds by default; 0 means never).")
    }

    func testUnknownHolderIsReportedAsNull() async throws {
        try holdTDLib(asPid: nil)
        let server = try await makeServer()
        let payload = try json(await server.handleToolCall(name: "send_message", arguments: [:]))
        XCTAssertEqual(payload["type"] as? String, "tdlib_in_use")
        XCTAssertTrue(payload["lock_holder_pid"] is NSNull)
    }

    // MARK: - Reader failures and arguments

    func testReaderThatCannotReadTheCacheReportsLocalReaderUnavailable() async throws {
        try holdTDLib(asPid: 4242)
        let cases: [(LocalReaderError, String)] = [
            (.unsupportedTDLibVersion("db.sqlite user_version 13"), "unsupported_tdlib_version"),
            (.keyNotFound, "key_not_found"),
            (.databaseUnreadable("disk I/O error"), "database_unreadable"),
            (.notAuthenticated, "not_authenticated"),
        ]
        let server = try await makeServer()
        for (error, reason) in cases {
            reader.error = error
            let result = await server.handleToolCall(name: "get_chat_history", arguments: arguments(for: "get_chat_history"))
            XCTAssertEqual(result.isError, true, reason)
            let payload = try json(result)
            XCTAssertEqual(payload["type"] as? String, "local_reader_unavailable", reason)
            XCTAssertEqual(payload["reason"] as? String, reason)
            XCTAssertNotNil(payload["message"] as? String, reason)
        }
    }

    func testReaderToolArgumentsAreCheckedAsInTDLibMode() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let result = await server.handleToolCall(name: "get_chat_history", arguments: [:])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(reader.calls.isEmpty)
    }

    /// The argument error's text reaches the caller, not just `isError` (#27):
    /// each case fails if the error arm returns any other message.
    func testArgumentErrorsCarryTheirMessage() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let output = Value.string(cache.appendingPathComponent("chat.md").path)
        let cases: [(tool: String, args: [String: Value], expected: String)] = [
            ("get_chat_history", [:], "Error: chat_id is required"),
            ("dump_chat_to_markdown", ["chat_id": .int(777)], "Error: output_path is required"),
            ("get_chat_history", ["chat_id": .int(777), "since_date": .string("2026/04/17")],
             "Error: Date format invalid: expected YYYY-MM-DD, got \"2026/04/17\""),
            ("search_messages", ["query": .string("a")], "Error: chat_id is required"),
        ]
        for c in cases {
            let result = await server.handleToolCall(name: c.tool, arguments: c.args)
            XCTAssertEqual(result.isError, true, c.expected)
            XCTAssertEqual(texts(result), [c.expected])
        }
        let tooMany = await server.handleToolCall(name: "dump_chat_to_markdown",
                                                  arguments: ["chat_id": .int(777), "output_path": output,
                                                              "max_messages": .int(10_001)])
        XCTAssertEqual(tooMany.isError, true)
        XCTAssertEqual(texts(tooMany).count, 1)
        XCTAssertTrue(texts(tooMany).first?.hasPrefix("Error: max_messages exceeds") == true, "\(texts(tooMany))")
        XCTAssertTrue(reader.calls.isEmpty, "\(reader.calls)")
    }

    // MARK: - Arguments checked before TDLib opens (#27, option B)

    /// A bad argument is reported without opening TDLib: the check runs
    /// before `beginCall()`, so it holds no lock and waits for no login.
    func testBadArgumentsAreReportedBeforeTDLibOpens() {
        let output = Value.string(cache.appendingPathComponent("chat.md").path)
        let cases: [(tool: String, args: [String: Value], expected: String)] = [
            ("get_chat_history", [:], "Error: chat_id is required"),
            ("get_chat_history", ["chat_id": .int(777), "until_date": .string("17-04-2026")],
             "Error: Date format invalid: expected YYYY-MM-DD, got \"17-04-2026\""),
            ("dump_chat_to_markdown", ["chat_id": .int(777)], "Error: output_path is required"),
            ("dump_chat_to_markdown", ["output_path": output], "Error: chat_id is required"),
        ]
        for c in cases {
            let result = preflightArgumentError(name: c.tool, arguments: c.args)
            XCTAssertEqual(result?.isError, true, c.expected)
            XCTAssertEqual(result.map(texts), [c.expected])
        }
        XCTAssertNil(preflightArgumentError(name: "get_chat_history", arguments: arguments(for: "get_chat_history")))
        XCTAssertNil(preflightArgumentError(name: "dump_chat_to_markdown", arguments: arguments(for: "dump_chat_to_markdown")))
        // Other tools keep their checks where they are.
        XCTAssertNil(preflightArgumentError(name: "search_messages", arguments: [:]))
    }

    /// handleToolCall runs that check before it opens TDLib. A test cannot
    /// drive this through handleToolCall: with TDLib free, beginCall() opens
    /// a real TDLib client.
    func testHandleToolCallChecksArgumentsBeforeOpeningTDLib() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheTelegramAllMCPCore/Server.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func handleToolCall(name: String"))
        let body = source[start.upperBound...]
        let check = try XCTUnwrap(body.range(of: "preflightArgumentError(name: name, arguments: args)"))
        let open = try XCTUnwrap(body.range(of: "lifecycle.beginCall()"))
        XCTAssertLessThan(check.lowerBound, open.lowerBound)
    }

    private struct NotOpened: LocalizedError {
        var errorDescription: String? { "test: TDLib was not opened" }
    }

    /// The same check driven through handleToolCall with TDLib free: the
    /// server's open function is replaced by one that counts and throws, so
    /// no real TDLib is opened. A bad argument never reaches it; good
    /// arguments do (#27 verify: the source-order test alone let a call that
    /// discards the check's result pass).
    func testBadArgumentsNeverOpenTDLib() async throws {
        let opens = OpenCounter()
        let server = try await CheTelegramAllMCPServer(
            lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()), idleTimeout: 600, reader: reader,
            openTDLib: { await opens.increment(); throw NotOpened() })
        let bad = await server.handleToolCall(name: "get_chat_history", arguments: [:])
        XCTAssertEqual(texts(bad), ["Error: chat_id is required"])
        let badDump = await server.handleToolCall(name: "dump_chat_to_markdown", arguments: ["chat_id": Value.int(777)])
        XCTAssertEqual(texts(badDump), ["Error: output_path is required"])
        let count = await opens.value
        XCTAssertEqual(count, 0)
        let good = await server.handleToolCall(name: "get_chat_history", arguments: arguments(for: "get_chat_history"))
        XCTAssertEqual(good.isError, true)
        XCTAssertEqual(texts(good), ["Error: test: TDLib was not opened"])
        let after = await opens.value
        XCTAssertEqual(after, 1)
    }

    private actor OpenCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    // MARK: - dump_chat_to_markdown output_path (#21)

    /// The root the server was given is the one the reader's dump receives.
    func testDumpPassesTheServersExportRootToTheReader() async throws {
        try holdTDLib(asPid: 4242)
        let root = cache.path
        for configured in [root, nil] as [String?] {
            let server = try await makeServer(exportRoot: configured)
            let result = await server.handleToolCall(name: "dump_chat_to_markdown", arguments: arguments(for: "dump_chat_to_markdown"))
            XCTAssertEqual(result.isError, false, "\(texts(result))")
        }
        XCTAssertEqual(reader.dumpExportRoots, [root, nil])
    }

    /// Scenarios "Relative path refused", "Traversal component refused" and
    /// "Non-Markdown target refused" while another process holds TDLib: the
    /// reader is never called.
    func testDumpOutputPathRulesApplyWhileTDLibIsHeld() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let cases = [
            ("chat.md", "Error: output_path must be an absolute path; got \"chat.md\""),
            ("/tmp/../x.md", "Error: output_path must not contain '..' components; got \"/tmp/../x.md\""),
            ("/Users/me/.zshrc", "Error: output_path must end in .md; got \"/Users/me/.zshrc\""),
        ]
        for (path, expected) in cases {
            let result = await server.handleToolCall(name: "dump_chat_to_markdown",
                                                     arguments: ["chat_id": .int(777), "output_path": .string(path)])
            XCTAssertEqual(result.isError, true, path)
            XCTAssertEqual(texts(result), [expected])
        }
        XCTAssertTrue(reader.calls.isEmpty, "\(reader.calls)")
    }

    /// Scenario "Local-cache dump honours the export root", through the real
    /// reader: the error names the path and the root, and comes before the
    /// cache (here one that cannot be opened) is read.
    func testLocalCacheDumpOutsideTheExportRootIsAnError() async throws {
        try holdTDLib(asPid: 4242)
        let root = cache.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = try await makeServer(reader: LocalTDLibReader(directory: "/nonexistent"), exportRoot: root.path)
        let outside = cache.appendingPathComponent("chat.md").path
        let result = await server.handleToolCall(name: "dump_chat_to_markdown",
                                                 arguments: ["chat_id": .int(777), "output_path": .string(outside)])
        XCTAssertEqual(result.isError, true)
        // The temporary paths are long enough that errorResultFromParse's
        // 256-character cap cuts the path at the end; the full text is pinned
        // in MarkdownExporterContractTests.
        let items = texts(result)
        XCTAssertEqual(items.count, 1)
        let expected = "Error: Output path is outside CHE_TELEGRAM_ALL_EXPORT_ROOT (\(root.path)) or could not be resolved: \(outside)"
        let shown = items.first ?? ""
        XCTAssertTrue(shown == expected || (shown.hasSuffix("...(truncated)")
                                            && expected.hasPrefix(String(shown.dropLast("...(truncated)".count)))), shown)
        XCTAssertTrue(shown.contains("(\(root.path))"), shown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    // MARK: - Source note

    private let utcPlus8 = TimeZone(secondsFromGMT: 8 * 3600)!

    /// Example "freshness lines" (the server's time zone is UTC+08:00).
    func testSourceNoteStatesTheHolderSkippedRecordsAndFreshness() {
        let note = localCacheNote(holderPid: 4242, result: reader.result, timeZone: utcPlus8)
        XCTAssertTrue(note.contains("source: local-cache"), note)
        XCTAssertTrue(note.contains("4242"), note)
        XCTAssertTrue(note.contains("undecodable records: 1"), note)
        XCTAssertTrue(note.contains("chat 777: newest cached message 2026-04-30"), note)
        XCTAssertTrue(note.contains("chat 888: no cached messages"), note)
        XCTAssertTrue(note.contains("newer messages can exist on Telegram"), note)
    }

    /// The date is the server's local date: Unix 1777480000 is 2026-04-29
    /// 16:26 UTC, already 2026-04-30 in UTC+08:00.
    func testFreshnessDateIsTheServersLocalDate() {
        let result = LocalTDLibReader.Result(json: "[]", undecodableCount: 0,
                                             freshness: [.init(chatId: 999, newest: .date(1_777_480_000))])
        let local = localCacheNote(holderPid: nil, result: result, timeZone: utcPlus8)
        let utc = localCacheNote(holderPid: nil, result: result, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(local.contains("chat 999: newest cached message 2026-04-30"), local)
        XCTAssertTrue(utc.contains("chat 999: newest cached message 2026-04-29"), utc)
    }
}
