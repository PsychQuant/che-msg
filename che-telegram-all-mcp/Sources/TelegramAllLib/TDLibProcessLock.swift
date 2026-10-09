import Foundation

/// Decides which process may open TDLib (PsychQuant/che-msg#58).
///
/// TDLib is held by another process when an exclusive non-blocking `flock` on
/// `che-telegram-all-mcp.tdlib.lock` fails, or when the legacy wrapper's lock
/// directory `che-telegram-all-mcp.lock` has an `owner.pid` naming a live
/// process other than this one. The holder of the flock records its PID in
/// `che-telegram-all-mcp.tdlib.owner`. The kernel drops the flock when the
/// process exits, so a crashed holder never leaves a stale lock behind.
public final class TDLibProcessLock {
    public enum State: Equatable {
        case acquired
        /// Held by another process; `pid` is nil when its owner is not recorded.
        case heldBy(pid: Int32?)
    }

    private let lockPath: String
    private let ownerPath: String
    private let legacyOwnerPath: String
    private let pid: Int32
    private var descriptor: Int32 = -1

    /// - Parameters:
    ///   - cacheDirectory: where the lock files live; `~/.cache` in production.
    ///   - pid: this process's PID.
    public init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache"),
                pid: Int32 = getpid()) {
        lockPath = cacheDirectory.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path
        ownerPath = cacheDirectory.appendingPathComponent("che-telegram-all-mcp.tdlib.owner").path
        legacyOwnerPath = cacheDirectory.appendingPathComponent("che-telegram-all-mcp.lock/owner.pid").path
        self.pid = pid
    }

    deinit {
        release()
    }

    /// Takes the lock unless another process holds TDLib. Taking it again
    /// while holding it succeeds.
    public func acquire() -> State {
        if descriptor >= 0 { return .acquired }
        if let legacy = liveLegacyOwner() { return .heldBy(pid: legacy) }
        try? FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .heldBy(pid: nil) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .heldBy(pid: recordedOwner())
        }
        // An old wrapper may have claimed its lock directory while the flock
        // was being taken; it opens TDLib without asking the flock.
        if let legacy = liveLegacyOwner() {
            flock(fd, LOCK_UN)
            close(fd)
            return .heldBy(pid: legacy)
        }
        descriptor = fd
        try? "\(pid)\n".write(toFile: ownerPath, atomically: true, encoding: .utf8)
        return .acquired
    }

    /// Releases the lock if this process holds it.
    public func release() {
        guard descriptor >= 0 else { return }
        if recordedOwner() == pid { try? FileManager.default.removeItem(atPath: ownerPath) }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// The PID of the process holding TDLib, or nil when nobody holds it or
    /// the holder did not record its PID.
    public func holder() -> Int32? {
        if descriptor >= 0 { return pid }
        if let legacy = liveLegacyOwner() { return legacy }
        let fd = open(lockPath, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        return recordedOwner()
    }

    private func liveLegacyOwner() -> Int32? {
        guard let owner = Self.readPid(legacyOwnerPath), owner != pid, Self.isAlive(owner) else { return nil }
        return owner
    }

    private func recordedOwner() -> Int32? {
        Self.readPid(ownerPath)
    }

    private static func readPid(_ path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    /// `kill(pid, 0)` succeeds, or fails only for lack of permission, when the
    /// process exists.
    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
