import Darwin
import XCTest
@testable import TelegramAllLib

/// Covers "TDLib opens on first use, not at startup" and "TDLib closes after
/// an idle period and releases the lock" (telegram-tdlib-lifecycle;
/// PsychQuant/che-msg#58, task 4.2) with an injected clock and a fake TDLib.
final class TDLibLifecycleTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private final class FakeTDLib: TDLibClosable, @unchecked Sendable {
        let serial: Int
        var closeResults: [Bool] = []
        var closeTimeouts: [TimeInterval] = []
        var closeDelayNanoseconds: UInt64 = 0

        init(serial: Int) { self.serial = serial }

        func close(timeout: TimeInterval) async -> Bool {
            closeTimeouts.append(timeout)
            if closeDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: closeDelayNanoseconds) }
            return closeResults.isEmpty ? true : closeResults.removeFirst()
        }
    }

    /// Counts and hands out fake TDLib instances.
    private final class Opener: @unchecked Sendable {
        var opened: [FakeTDLib] = []
        var delayNanoseconds: UInt64 = 0
        var failure: Error?
        var configure: (FakeTDLib) -> Void = { _ in }

        func open() async throws -> FakeTDLib {
            if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
            if let failure { throw failure }
            let client = FakeTDLib(serial: opened.count + 1)
            configure(client)
            opened.append(client)
            return client
        }
    }

    private final class Log: @unchecked Sendable {
        var lines: [String] = []
    }

    private var cache: URL!
    private let clock = FakeClock()
    private let opener = Opener()
    private let log = Log()

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    private func makeLifecycle(idleTimeout: TimeInterval? = 600) -> TDLibLifecycle<FakeTDLib> {
        TDLibLifecycle(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                       idleTimeout: idleTimeout,
                       clock: { [clock] in clock.now },
                       log: { [log] in log.lines.append($0) },
                       open: { [opener] in try await opener.open() })
    }

    private var lockPath: String { cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path }

    /// True when another open file description can take the flock right now.
    private func lockIsFree() -> Bool {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    // MARK: - Spec example "idle close and reopen timeline"

    func testIdleCloseAndReopenTimeline() async throws {
        let lifecycle = makeLifecycle()
        // 0 s: server starts
        var isOpen = await lifecycle.isOpen
        XCTAssertFalse(isOpen)
        XCTAssertTrue(lockIsFree())
        XCTAssertTrue(opener.opened.isEmpty)

        clock.now = 10        // get_chats
        let first = try await lifecycle.client()
        XCTAssertEqual(first.serial, 1)
        XCTAssertFalse(lockIsFree())

        clock.now = 400       // get_chat_history
        let again = try await lifecycle.client()
        XCTAssertTrue(again === first)

        clock.now = 999       // idle check: 599 s since the last call
        await lifecycle.checkIdle()
        isOpen = await lifecycle.isOpen
        XCTAssertTrue(isOpen)

        clock.now = 1000      // idle check: 600 s since the last call
        await lifecycle.checkIdle()
        isOpen = await lifecycle.isOpen
        XCTAssertFalse(isOpen)
        XCTAssertTrue(lockIsFree())
        XCTAssertEqual(first.closeTimeouts, [30])

        clock.now = 1200      // search_messages, lock free
        let reopened = try await lifecycle.client()
        XCTAssertEqual(reopened.serial, 2)
        XCTAssertFalse(lockIsFree())
    }

    // MARK: - Close that does not finish keeps the lock

    func testCloseThatDoesNotFinishKeepsTheLockAndRetries() async throws {
        opener.configure = { $0.closeResults = [false, true] }
        let lifecycle = makeLifecycle()
        let client = try await lifecycle.client()

        clock.now = 700
        await lifecycle.checkIdle()
        var isOpen = await lifecycle.isOpen
        XCTAssertTrue(isOpen)
        XCTAssertFalse(lockIsFree())
        XCTAssertEqual(log.lines.count, 1)

        clock.now = 730
        await lifecycle.checkIdle()
        isOpen = await lifecycle.isOpen
        XCTAssertFalse(isOpen)
        XCTAssertTrue(lockIsFree())
        XCTAssertEqual(client.closeTimeouts, [30, 30])
        XCTAssertEqual(log.lines.count, 1)
    }

    // MARK: - Lock held elsewhere

    func testLockHeldByAnotherProcessDoesNotOpenTDLib() async throws {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try "4242\n".write(toFile: cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner").path,
                           atomically: true, encoding: .utf8)
        do {
            _ = try await makeLifecycle().client()
            XCTFail("expected heldByAnotherProcess")
        } catch let error as TDLibLifecycle<FakeTDLib>.AccessError {
            XCTAssertEqual(error, .heldByAnotherProcess(pid: 4242))
        }
        XCTAssertTrue(opener.opened.isEmpty)
    }

    // MARK: - Concurrency and failures

    func testConcurrentFirstCallsOpenTDLibOnce() async throws {
        opener.delayNanoseconds = 50_000_000
        let lifecycle = makeLifecycle()
        async let a = lifecycle.client()
        async let b = lifecycle.client()
        let (first, second) = try await (a, b)
        XCTAssertTrue(first === second)
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testCallDuringCloseWaitsAndReopens() async throws {
        opener.configure = { $0.closeDelayNanoseconds = 100_000_000 }
        let lifecycle = makeLifecycle()
        _ = try await lifecycle.client()
        clock.now = 700
        let closing = Task { await lifecycle.checkIdle() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let client = try await lifecycle.client()
        await closing.value
        XCTAssertEqual(client.serial, 2)
        let isOpen = await lifecycle.isOpen
        XCTAssertTrue(isOpen)
        XCTAssertFalse(lockIsFree())
    }

    func testOpenFailureReleasesTheLock() async throws {
        struct Boom: Error {}
        opener.failure = Boom()
        let lifecycle = makeLifecycle()
        do {
            _ = try await lifecycle.client()
            XCTFail("expected the open failure")
        } catch is Boom {}
        XCTAssertTrue(lockIsFree())
        let isOpen = await lifecycle.isOpen
        XCTAssertFalse(isOpen)
    }

    func testZeroTimeoutNeverCloses() async throws {
        let lifecycle = makeLifecycle(idleTimeout: nil)
        _ = try await lifecycle.client()
        clock.now = 1_000_000
        await lifecycle.checkIdle()
        let isOpen = await lifecycle.isOpen
        XCTAssertTrue(isOpen)
    }

    // MARK: - Shutdown

    /// The server closes TDLib before the process exits, so TDLib never shuts
    /// down concurrently with the process's own teardown.
    func testShutdownClosesAnOpenClientAndReleasesTheLock() async throws {
        let lifecycle = makeLifecycle(idleTimeout: nil)
        let client = try await lifecycle.client()
        await lifecycle.shutdown()
        let isOpen = await lifecycle.isOpen
        XCTAssertFalse(isOpen)
        XCTAssertTrue(lockIsFree())
        XCTAssertEqual(client.closeTimeouts, [30])
    }

    func testShutdownDuringOpenWaitsAndThenCloses() async throws {
        opener.delayNanoseconds = 100_000_000
        let lifecycle = makeLifecycle()
        let opening = Task { try await lifecycle.client() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await lifecycle.shutdown()
        let client = try await opening.value
        XCTAssertEqual(client.closeTimeouts, [30])
        let isOpen = await lifecycle.isOpen
        XCTAssertFalse(isOpen)
        XCTAssertTrue(lockIsFree())
    }

    func testShutdownWithNothingOpenDoesNothing() async {
        let lifecycle = makeLifecycle()
        await lifecycle.shutdown()
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(lockIsFree())
    }

    // MARK: - Spec example "idle timeout values"

    func testIdleTimeoutValues() {
        let cases: [(String?, TimeInterval?, Int)] = [
            (nil, 600, 0),
            ("120", 120, 0),
            ("0", nil, 0),
            ("abc", 600, 1),
            ("-5", 600, 1),
        ]
        for (value, expected, warnings) in cases {
            var lines: [String] = []
            XCTAssertEqual(IdleTimeout.parse(value, warn: { lines.append($0) }), expected, "value \(value ?? "unset")")
            XCTAssertEqual(lines.count, warnings, "value \(value ?? "unset")")
        }
    }
}
