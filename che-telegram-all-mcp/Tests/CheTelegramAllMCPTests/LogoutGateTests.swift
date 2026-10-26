import Darwin
import MCP
import XCTest
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// One `logout` at a time (PsychQuant/che-msg#64, finding 3): a second logout
/// that arrives while one is running fails at once instead of resetting a
/// client the first may already have discarded. No TDLib is opened: the gate
/// is tested on its own, and the server's wiring with TDLib held by "another
/// process" (a second open file description holding the flock).
final class LogoutGateTests: XCTestCase {
    /// Lets a test wait for something that happens in another task.
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var waiter: CheckedContinuation<Void, Never>?

        func fire() {
            lock.lock()
            fired = true
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if fired {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    private static let busyText = "Error: another logout is already running in this server; this call did nothing. "
        + "Wait for that logout's result before calling logout again."

    private func ok(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private func text(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }

    // MARK: - The gate

    func testASecondLogoutWhileOneRunsFailsAtOnceWithoutRunning() async {
        let gate = LogoutGate()
        let entered = Signal(), release = Signal()
        let first = Task { await gate.run { entered.fire(); await release.wait(); return self.ok("first") } }
        await entered.wait()

        var secondRan = false
        let second = await gate.run { secondRan = true; return ok("second") }
        XCTAssertFalse(secondRan, "a logout that arrives while one runs is refused, not queued")
        XCTAssertEqual(second.isError, true)
        XCTAssertEqual(text(second), Self.busyText)

        release.fire()
        let firstResult = await first.value
        XCTAssertEqual(text(firstResult), "first", "the running logout is not affected")
        let third = await gate.run { ok("third") }
        XCTAssertEqual(text(third), "third", "the next logout runs once the first has finished")
    }

    func testALogoutThatFailedFreesTheGate() async {
        let gate = LogoutGate()
        let failed = await gate.run {
            CallTool.Result(content: [.text(text: "Error: x", annotations: nil, _meta: nil)], isError: true)
        }
        XCTAssertEqual(failed.isError, true)
        let next = await gate.run { ok("next") }
        XCTAssertEqual(text(next), "next")
    }

    // MARK: - The server

    private var cache: URL!

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("logout-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    /// Holds the TDLib flock as another process would, so no call opens TDLib.
    private func holdTDLib() throws {
        let fd = open(cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { close(fd) }
        try "4242\n".write(to: cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner"), atomically: true, encoding: .utf8)
    }

    private func type(_ result: CallTool.Result) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])?["type"] as? String
    }

    /// The gate is checked before TDLib is asked for: with a logout running,
    /// a second one is refused even where it would otherwise get `tdlib_in_use`.
    /// Other tools are not gated, and without a running logout `logout`
    /// answers as before.
    func testTheServerRefusesASecondLogoutBeforeAskingForTDLib() async throws {
        try holdTDLib()
        let server = try await CheTelegramAllMCPServer(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                                                       idleTimeout: 600)
        XCTAssertTrue(server.logoutGate.enter(), "plays a logout that is running")
        let busy = await server.handleToolCall(name: "logout", arguments: [:])
        XCTAssertEqual(busy.isError, true)
        XCTAssertEqual(text(busy), Self.busyText)
        let status = await server.handleToolCall(name: "auth_status", arguments: [:])
        XCTAssertEqual(type(status), "tdlib_in_use", "other tools are not gated")

        server.logoutGate.leave()
        let logout = await server.handleToolCall(name: "logout", arguments: [:])
        XCTAssertEqual(type(logout), "tdlib_in_use")
        XCTAssertTrue(server.logoutGate.enter(), "a finished logout leaves the gate free")
        server.logoutGate.leave()
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen)
    }
}
