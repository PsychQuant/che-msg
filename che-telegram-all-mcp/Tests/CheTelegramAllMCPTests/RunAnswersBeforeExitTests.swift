import XCTest
import MCP
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// Scenario "Connection end closes TDLib before exit" (telegram-tdlib-lifecycle,
/// PsychQuant/che-msg#57): when the input ends, `run()` answers the requests it
/// has already read before it closes TDLib and returns, waiting a bounded time.
final class RunAnswersBeforeExitTests: XCTestCase {

    /// Answers `dump_chat_to_markdown` after `delay` seconds, or, with no delay,
    /// once `release()` is called. No other read is used.
    private final class ExportReader: LocalCacheReading, @unchecked Sendable {
        private let delay: TimeInterval?
        private var releaseExport: AsyncStream<Void>.Continuation!
        private let released: AsyncStream<Void>

        init(delay: TimeInterval?) {
            self.delay = delay
            var continuation: AsyncStream<Void>.Continuation!
            released = AsyncStream { continuation = $0 }
            releaseExport = continuation
        }

        func release() { releaseExport.finish() }

        private func unused() -> Error { LocalReaderError.notAuthenticated }
        func getChats(limit: Int) throws -> LocalTDLibReader.Result { throw unused() }
        func searchChats(query: String, limit: Int) throws -> LocalTDLibReader.Result { throw unused() }
        func getChatHistory(chatId: Int64, limit: Int, fromMessageId: Int64, maxMessages: Int?,
                            sinceDate: Date?, untilDate: Date?) throws -> LocalTDLibReader.Result { throw unused() }
        func searchMessages(chatId: Int64, query: String, limit: Int) throws -> LocalTDLibReader.Result { throw unused() }
        func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int, sinceDate: Date?,
                                untilDate: Date?, selfLabel: String) async throws -> LocalTDLibReader.Result {
            if let delay {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                for await _ in released {}
            }
            return LocalTDLibReader.Result(json: #"{"exported":true}"#, undecodableCount: 0, freshness: [])
        }
    }

    private var cache: URL!

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    /// Holds the TDLib flock as another process would, so tool calls are
    /// answered from the (fake) local cache and no TDLib client is created.
    private func holdTDLib() {
        let fd = open(cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { close(fd) }
    }

    private func makeServer(_ transport: ScriptedTransport, reader: ExportReader = ExportReader(delay: 0),
                            answerTimeout: TimeInterval) async throws -> CheTelegramAllMCPServer {
        try await CheTelegramAllMCPServer(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                                          idleTimeout: nil, reader: reader,
                                          transport: transport, answerTimeout: answerTimeout)
    }

    private func exportCall(id: Int) -> String {
        let path = cache.appendingPathComponent("chat.md").path
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"dump_chat_to_markdown","arguments":{"chat_id":777,"output_path":"\#(path)"}}}"#
    }

    /// The reproduction in the issue: `initialize`, `notifications/initialized`
    /// and `tools/list`, then the input ends at once. Each answer takes 50 ms to
    /// write, so a `run()` that does not wait returns before either is sent.
    func testRequestsReadBeforeTheInputEndsAreAnsweredBeforeRunReturns() async throws {
        let transport = ScriptedTransport([ScriptedMessages.initialize(id: 1), ScriptedMessages.initialized,
                                           ScriptedMessages.toolsList(id: 2)], sendDelay: 0.05)
        let server = try await makeServer(transport, answerTimeout: 10)
        try await server.run()
        let ids = await transport.respondedIDs
        XCTAssertEqual(ids.sorted(), [1, 2])
        let objects = await transport.sentObjects
        XCTAssertTrue(objects.allSatisfy { $0["result"] != nil }, "\(objects)")
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen)
    }

    /// A tool call still running when the input ends is answered before
    /// `run()` returns, and the wait ends with the answer, not at the bound.
    func testASlowToolCallIsAnsweredBeforeRunReturns() async throws {
        holdTDLib()
        let transport = ScriptedTransport([ScriptedMessages.initialize(id: 1), ScriptedMessages.initialized,
                                           exportCall(id: 2)])
        let server = try await makeServer(transport, reader: ExportReader(delay: 0.3), answerTimeout: 10)
        let start = ContinuousClock.now
        try await server.run()
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        let ids = await transport.respondedIDs
        XCTAssertEqual(ids.sorted(), [1, 2])
        let objects = await transport.sentObjects
        let call = try XCTUnwrap(objects.first { $0["id"] as? Int == 2 })
        let result = try XCTUnwrap(call["result"] as? [String: Any], "\(call)")
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(text, #"{"exported":true}"#)
    }

    /// A call that never answers holds `run()` only for the bound; the
    /// requests that were answered are still sent.
    func testRunReturnsAfterTheBoundWhenARequestIsNeverAnswered() async throws {
        holdTDLib()
        let reader = ExportReader(delay: nil)
        addTeardownBlock { reader.release() }
        let transport = ScriptedTransport([ScriptedMessages.initialize(id: 1), ScriptedMessages.initialized,
                                           exportCall(id: 2)])
        let server = try await makeServer(transport, reader: reader, answerTimeout: 0.3)
        let start = ContinuousClock.now
        try await server.run()
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300), "run() must wait for the unanswered call")
        XCTAssertLessThan(elapsed, .seconds(5), "run() must stop waiting at the bound")
        let ids = await transport.respondedIDs
        XCTAssertEqual(ids, [1])
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen)
    }

    func testTheDefaultBoundIsTheTDLibCloseTimeout() {
        XCTAssertEqual(CheTelegramAllMCPServer.defaultAnswerTimeout, 30)
        XCTAssertEqual(CheTelegramAllMCPServer.defaultAnswerTimeout, TDLibLifecycle<TDLibClient>.closeTimeout)
    }

    // MARK: - The built server

    /// The built server next to the test bundle, or nil when it is not built.
    private func serverBinary() -> URL? {
        let buildDir = Bundle(for: type(of: self)).bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let binary = buildDir.appendingPathComponent("CheTelegramAllMCP")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    /// A client that has closed its end of stdout (it crashed, or `| head -n 1`):
    /// writing an answer fails with EPIPE instead of killing the server with
    /// SIGPIPE, so the server still closes TDLib and exits with status 0. Only
    /// `initialize` and `tools/list` are sent, so TDLib is never opened; HOME
    /// points at a scratch directory all the same.
    func testTheServerExitsNormallyWhenTheClientClosedStdout() throws {
        guard let binary = serverBinary() else {
            throw XCTSkip("CheTelegramAllMCP binary not built — skip subprocess test")
        }
        let input = cache.appendingPathComponent("input.jsonl")
        try [ScriptedMessages.initialize(id: 1), ScriptedMessages.initialized, ScriptedMessages.toolsList(id: 2)]
            .map { $0 + "\n" }.joined().write(to: input, atomically: true, encoding: .utf8)
        // A pipe whose read end is closed before the server starts: its
        // first write has no reader.
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])
        let stdout = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        let stderr = Pipe()

        let process = Process()
        process.executableURL = binary
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.contains("TELEGRAM") }
        environment["HOME"] = cache.path
        environment["CFFIXED_USER_HOME"] = cache.path
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try? stdout.close()

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("the server did not exit within 20 s")
        }
        let log = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationReason, .exit,
                       "the server was killed by signal \(process.terminationStatus); stderr: \(log)")
        XCTAssertEqual(process.terminationStatus, 0, "stderr: \(log)")
    }
}
