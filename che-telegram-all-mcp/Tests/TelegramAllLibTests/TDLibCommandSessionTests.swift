import Darwin
import XCTest
@testable import TelegramAllLib

/// The `telegram-all` CLI takes the server's TDLib lock (PsychQuant/che-msg#61).
/// Each test uses its own cache directory and a fake TDLib; "another process
/// holds the flock" is played by a second open file description, as in
/// `TDLibProcessLockTests`.
final class TDLibCommandSessionTests: XCTestCase {
    private final class FakeTDLib: TDLibClosable, @unchecked Sendable {
        var closeResult = true
        /// Whether the lock was free when each close ran.
        var lockFreeAtClose: [Bool] = []
        var lockIsFree: () -> Bool = { true }

        func close(timeout: TimeInterval) async -> Bool {
            lockFreeAtClose.append(lockIsFree())
            return closeResult
        }
    }

    private struct Failure: Error, Equatable {}

    private final class Log: @unchecked Sendable {
        var lines: [String] = []
    }

    private var cache: URL!
    private let log = Log()

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    private var lockPath: String { cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path }
    private var ownerPath: String { cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner").path }

    private func makeLock() -> TDLibProcessLock { TDLibProcessLock(cacheDirectory: cache, pid: getpid()) }

    private func makeClient() -> FakeTDLib {
        let client = FakeTDLib()
        client.lockIsFree = { [unowned self] in self.lockIsFree() }
        return client
    }

    /// True when another open file description can take the flock right now.
    private func lockIsFree() -> Bool {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    /// Holds the flock through a separate open file description; records
    /// `pid` as its owner when given.
    private func holdFlock(asPid pid: Int32?) throws {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        if let pid { try "\(pid)\n".write(toFile: ownerPath, atomically: true, encoding: .utf8) }
        addTeardownBlock { close(fd) }
    }

    private func run<T>(_ lock: TDLibProcessLock, client: FakeTDLib? = nil, openFailure: Error? = nil,
                        body: (FakeTDLib) async throws -> T) async throws -> T {
        try await TDLibCommandSession.run(lock: lock, log: { [log] in log.lines.append($0) }, open: {
            if let openFailure { throw openFailure }
            return client ?? makeClient()
        }, body: body)
    }

    // MARK: - Lock free

    func testTheLockIsHeldWhileTheCommandRunsAndReleasedAfter() async throws {
        let client = makeClient()
        let value = try await run(makeLock(), client: client) { _ -> Int in
            XCTAssertFalse(lockIsFree(), "the command runs while this process holds the lock")
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertTrue(lockIsFree())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerPath))
        XCTAssertEqual(client.lockFreeAtClose.count, 1, "TDLib is closed once, explicitly")
    }

    /// Strategy item 3: TDLib closes first, and only then is the lock released.
    func testTDLibClosesBeforeTheLockIsReleased() async throws {
        let client = makeClient()
        try await run(makeLock(), client: client) { _ in }
        XCTAssertEqual(client.lockFreeAtClose, [false])
        XCTAssertTrue(lockIsFree())
    }

    func testACommandThatFailsStillClosesTDLibThenReleasesTheLock() async throws {
        let client = makeClient()
        do {
            try await run(makeLock(), client: client) { _ -> Void in throw Failure() }
            XCTFail("the command's error must reach the caller")
        } catch is Failure {}
        XCTAssertEqual(client.lockFreeAtClose, [false])
        XCTAssertTrue(lockIsFree())
    }

    func testTDLibThatFailsToOpenReleasesTheLock() async throws {
        do {
            try await run(makeLock(), openFailure: Failure()) { _ in XCTFail("no command without TDLib") }
            XCTFail("the open error must reach the caller")
        } catch is Failure {}
        XCTAssertTrue(lockIsFree())
    }

    /// A close that does not finish keeps the lock until the process exits,
    /// so no other process opens TDLib while this one may still be running it,
    /// and fails the command, so that a script can tell.
    func testACloseThatDoesNotFinishKeepsTheLockAndFailsTheCommand() async throws {
        let client = makeClient()
        client.closeResult = false
        do {
            try await run(makeLock(), client: client) { _ in }
            XCTFail("a close that does not finish must fail the command")
        } catch is TDLibCommandSession.NotClosed {}
        XCTAssertFalse(lockIsFree(), "the lock outlives the lock object; the kernel drops it at exit")
        XCTAssertEqual(log.lines, [
            "telegram-all: TDLib did not report authorizationStateClosed within 30 s; "
                + "keeping the TDLib lock until telegram-all exits",
        ])
    }

    /// When the command itself failed, its error is the one reported.
    func testAFailedCommandWhoseCloseDoesNotFinishReportsTheCommandsError() async throws {
        let client = makeClient()
        client.closeResult = false
        do {
            try await run(makeLock(), client: client) { _ -> Void in throw Failure() }
            XCTFail("the command's error must reach the caller")
        } catch is Failure {}
        XCTAssertFalse(lockIsFree())
        XCTAssertEqual(log.lines.count, 1)
    }

    // MARK: - Lock held elsewhere

    func testALockHeldElsewhereNamesTheHolderAndOpensNothing() async throws {
        try holdFlock(asPid: 4242)
        do {
            try await run(makeLock(), openFailure: Failure()) { _ in XCTFail("no command while TDLib is held") }
            XCTFail("a held lock must stop the command")
        } catch let held as TDLibCommandSession.Held {
            XCTAssertEqual(held.message, TDLibCommandSession.heldMessage(holderPid: 4242))
        }
        XCTAssertEqual(try String(contentsOfFile: ownerPath, encoding: .utf8), "4242\n",
                       "the holder's owner file is left alone")
    }

    func testAcquireReturnsNilWhenTakenAndTheMessageWhenHeld() throws {
        let lock = makeLock()
        XCTAssertNil(TDLibCommandSession.acquire(lock))
        lock.release()
        try holdFlock(asPid: 4242)
        XCTAssertEqual(TDLibCommandSession.acquire(makeLock()), TDLibCommandSession.heldMessage(holderPid: 4242))
    }

    /// A holder that recorded no PID (`heldBy(pid: nil)`).
    func testAHolderWithoutARecordedPidIsAnUnknownHolder() throws {
        try holdFlock(asPid: nil)
        XCTAssertEqual(TDLibCommandSession.acquire(makeLock()), TDLibCommandSession.heldMessage(holderPid: nil))
    }

    /// The legacy wrapper's lock directory counts as a holder through this
    /// function too (`TDLibProcessLock` covers the cases).
    func testALiveLegacyWrapperIsAHolder() throws {
        let script = cache.appendingPathComponent("che-telegram-all-mcp-wrapper.sh")
        try "sleep 30\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        let legacy = cache.appendingPathComponent("che-telegram-all-mcp.lock")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "\(process.processIdentifier)\n".write(to: legacy.appendingPathComponent("owner.pid"),
                                                    atomically: true, encoding: .utf8)
        XCTAssertEqual(TDLibCommandSession.acquire(makeLock()),
                       TDLibCommandSession.heldMessage(holderPid: process.processIdentifier))
        XCTAssertTrue(lockIsFree())
    }

    func testTheMessageNamesTheHolderOrSaysItIsUnknown() {
        let release = "Try again once it has released TDLib: a telegram-all command releases it when it finishes; "
            + "a Claude Code session using telegram-all releases it when the session ends, and can release it earlier, "
            + "once it has had no calls for its idle timeout (CHE_TELEGRAM_ALL_IDLE_TIMEOUT, 600 seconds by default; "
            + "0 means never)."
        XCTAssertEqual(TDLibProcessLock.holderReleaseHint, release)
        XCTAssertEqual(TDLibCommandSession.heldMessage(holderPid: 4242),
                       "telegram-all: TDLib is in use by process 4242, so this command did not open it. " + release)
        XCTAssertEqual(TDLibCommandSession.heldMessage(holderPid: nil),
                       "telegram-all: TDLib is in use by another process (unknown holder), so this command did not "
                       + "open it. " + release)
    }

    // MARK: - The CLI

    /// Every TDLib client the CLI creates is opened by `TDLibCommandSession.run`,
    /// so no command opens TDLib without the lock. The CLI target has no tests
    /// of its own; this reads its sources.
    func testTheCLIOpensTDLibOnlyUnderTheLock() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/telegram-all")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let creation = try NSRegularExpression(pattern: #"\bTDLibClient\s*(\.\s*init)?\s*\("#)
        // Other ways to reach the initializer: a function reference or an alias.
        let indirect = try NSRegularExpression(pattern: #"\bTDLibClient\s*\.\s*init\b|\btypealias\b[^=]*=[^\n]*\bTDLibClient\b"#)
        var creations: [(file: String, previous: String, line: String)] = []
        for file in files {
            let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for (index, line) in lines.enumerated()
            where creation.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) > 0 {
                creations.append((file, index > 0 ? lines[index - 1] : "", line))
            }
            XCTAssertFalse(lines.contains { $0.contains("TDLibLifecycle") || $0.contains(".acquire()") }, file)
            for line in lines where !line.contains("open: {") {
                let hits = indirect.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
                XCTAssertEqual(hits, 0, "\(file): TDLibClient reached other than by the one construction: \(line)")
            }
        }
        XCTAssertEqual(creations.count, 1, "one place creates TDLib: \(creations.map(\.line))")
        XCTAssertTrue(creations.first?.previous.contains("TDLibCommandSession.run(") == true,
                      creations.first.map { "\($0.file): \($0.previous)" } ?? "")
        XCTAssertTrue(creations.first?.line.contains("open: {") == true, creations.first?.line ?? "")
    }
}
