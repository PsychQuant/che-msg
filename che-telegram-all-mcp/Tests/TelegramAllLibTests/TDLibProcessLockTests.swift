import Darwin
import XCTest
@testable import TelegramAllLib

/// Covers "Lock ownership honors the legacy wrapper lock" (telegram-tdlib-lifecycle;
/// PsychQuant/che-msg#58, task 4.1). Each test uses its own cache directory.
///
/// "Another process holds the flock" is played by a second open file
/// description of the lock file: flock locks belong to the open file
/// description, so a second `open` conflicts exactly as another process would.
final class TDLibProcessLockTests: XCTestCase {
    private var cache: URL!
    private let ownPid: Int32 = getpid()

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    private var lockPath: String { cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path }
    private var ownerPath: String { cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner").path }
    private var legacyDir: URL { cache.appendingPathComponent("che-telegram-all-mcp.lock") }

    private func makeLock() -> TDLibProcessLock { TDLibProcessLock(cacheDirectory: cache, pid: ownPid) }

    /// Holds the flock through a separate open file description, recording
    /// `pid` as its owner the way a server would.
    private func holdFlock(asPid pid: Int32) throws -> Int32 {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try "\(pid)\n".write(toFile: ownerPath, atomically: true, encoding: .utf8)
        addTeardownBlock { close(fd) }
        return fd
    }

    /// True when a fresh open file description can take the flock right now.
    private func flockIsFree() -> Bool {
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    private func writeLegacyOwner(_ pid: Int32) throws {
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try "\(pid)\n".write(to: legacyDir.appendingPathComponent("owner.pid"), atomically: true, encoding: .utf8)
    }

    private func liveProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process.processIdentifier
    }

    /// A running process whose command line names the legacy wrapper script,
    /// as `/bin/bash …/che-telegram-all-mcp-wrapper.sh` does.
    private func liveLegacyWrapper() throws -> Int32 {
        let script = cache.appendingPathComponent("che-telegram-all-mcp-wrapper.sh")
        try "sleep 30\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        try process.run()
        addTeardownBlock { process.terminate(); process.waitUntilExit() }
        return process.processIdentifier
    }

    private func exitedProcess() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    // MARK: - The four cases of task 4.1

    func testFreeLockIsAcquiredAndRecordsTheOwner() throws {
        let lock = makeLock()
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(try String(contentsOfFile: ownerPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(ownPid)")
        XCTAssertFalse(flockIsFree())
    }

    func testFlockHeldElsewhereReportsItsOwner() throws {
        _ = try holdFlock(asPid: 4242)
        XCTAssertEqual(makeLock().acquire(), .heldBy(pid: 4242))
        XCTAssertEqual(try String(contentsOfFile: ownerPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "4242")
    }

    /// Scenario "Legacy wrapper lock with a live owner blocks opening".
    func testLegacyOwnerThatIsAliveHoldsTDLib() throws {
        let legacyPid = try liveLegacyWrapper()
        try writeLegacyOwner(legacyPid)
        XCTAssertEqual(makeLock().acquire(), .heldBy(pid: legacyPid))
        XCTAssertTrue(flockIsFree(), "the flock must not stay taken while the legacy owner holds TDLib")
    }

    /// A crashed wrapper can leave the directory behind, and its PID can later
    /// belong to an unrelated process: only the wrapper script counts.
    func testLegacyOwnerPidReusedByAnotherProgramIsIgnored() throws {
        try writeLegacyOwner(try liveProcess())
        XCTAssertEqual(makeLock().acquire(), .acquired)
    }

    /// Scenario "Legacy wrapper lock with a dead owner is ignored".
    func testLegacyOwnerThatExitedIsIgnored() throws {
        try writeLegacyOwner(try exitedProcess())
        XCTAssertEqual(makeLock().acquire(), .acquired)
    }

    // MARK: - Boundaries

    func testReleaseFreesTheFlockAndRemovesTheOwnerFile() throws {
        let lock = makeLock()
        XCTAssertEqual(lock.acquire(), .acquired)
        lock.release()
        XCTAssertTrue(flockIsFree())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerPath))
    }

    func testAcquiringTwiceKeepsTheLock() {
        let lock = makeLock()
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertFalse(flockIsFree())
    }

    func testLegacyOwnerNamingThisProcessDoesNotBlock() throws {
        try writeLegacyOwner(ownPid)
        XCTAssertEqual(makeLock().acquire(), .acquired)
    }

    func testEmptyLegacyDirectoryDoesNotBlock() throws {
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        XCTAssertEqual(makeLock().acquire(), .acquired)
    }

    /// A lock file that cannot be created is reported once on the log instead
    /// of passing silently as "held by another process".
    func testLockFileThatCannotBeOpenedIsReportedOnce() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.path)
        addTeardownBlock { [cache] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache!.path)
        }
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let lock = TDLibProcessLock(cacheDirectory: cache, pid: ownPid, log: { lines.all.append($0) })
        XCTAssertEqual(lock.acquire(), .heldBy(pid: nil))
        XCTAssertEqual(lock.acquire(), .heldBy(pid: nil))
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all.first?.contains("che-telegram-all-mcp.tdlib.lock") == true, lines.all.first ?? "")
    }

    func testHolderNamesWhoeverHoldsTDLib() throws {
        let lock = makeLock()
        XCTAssertNil(lock.holder())
        _ = try holdFlock(asPid: 4242)
        XCTAssertEqual(lock.holder(), 4242)
    }

    func testHolderIsThisProcessWhileItHoldsTheLock() {
        let lock = makeLock()
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(lock.holder(), ownPid)
    }
}
