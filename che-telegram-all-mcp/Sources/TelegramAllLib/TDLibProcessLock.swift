import Foundation

/// Decides which process may open TDLib (PsychQuant/che-msg#58).
///
/// TDLib is held by another process when an exclusive non-blocking `flock` on
/// `che-telegram-all-mcp.tdlib.lock` fails, or when the legacy wrapper's lock
/// directory `che-telegram-all-mcp.lock` has an `owner.pid` naming a live
/// process, other than this one, that runs the legacy wrapper script. The holder of the flock records its PID in
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
    private let log: (String) -> Void
    private var descriptor: Int32 = -1
    private var reportedOpenFailure = false

    /// - Parameters:
    ///   - cacheDirectory: where the lock files live; `~/.cache` in production.
    ///   - pid: this process's PID.
    public init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache"),
                pid: Int32 = getpid(), log: @escaping (String) -> Void = { fputs($0 + "\n", stderr) }) {
        lockPath = cacheDirectory.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path
        ownerPath = cacheDirectory.appendingPathComponent("che-telegram-all-mcp.tdlib.owner").path
        legacyOwnerPath = cacheDirectory.appendingPathComponent("che-telegram-all-mcp.lock/owner.pid").path
        self.pid = pid
        self.log = log
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
        guard fd >= 0 else {
            // Without this line the failure would read as "held by another
            // process" with nothing to say why.
            if !reportedOpenFailure {
                reportedOpenFailure = true
                log("che-telegram-all-mcp: cannot open the TDLib lock file \(lockPath): "
                    + "\(String(cString: strerror(errno))); TDLib will not be opened")
            }
            return .heldBy(pid: nil)
        }
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

    /// The legacy wrapper's PID when it is still running. A wrapper killed
    /// without its exit cleanup leaves the directory behind, and after a reboot
    /// its PID can belong to an unrelated program; so the process must also be
    /// running the wrapper script. When its arguments cannot be read, it is
    /// assumed to be the wrapper, so that two processes never open TDLib.
    private func liveLegacyOwner() -> Int32? {
        guard let owner = Self.readPid(legacyOwnerPath), owner != pid, Self.isAlive(owner) else { return nil }
        if let arguments = Self.arguments(of: owner),
           !arguments.contains(where: { $0.hasSuffix(Self.legacyWrapperScript) }) {
            return nil
        }
        return owner
    }

    static let legacyWrapperScript = "che-telegram-all-mcp-wrapper.sh"

    /// The command-line arguments of `pid` (`KERN_PROCARGS2`: argc, the
    /// executable path, padding, then the arguments), or nil when they cannot
    /// be read.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24)
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
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
