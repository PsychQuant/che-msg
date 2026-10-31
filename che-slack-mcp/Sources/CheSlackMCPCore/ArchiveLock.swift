import Foundation

/// Keeps two archives of one conversation of one workspace into one
/// `output_dir` from running at once (spec: slack-chat-archive, "Archive
/// concurrency and partial progress"). A run reads, merges and replaces the
/// day files and the manifest, so two at once would drop each other's
/// blocks, or move the bookmark past messages the other has not written.
///
/// The lock is an exclusive, non-blocking `flock` on the conversation
/// directory itself, opened `O_RDONLY | O_DIRECTORY | O_NOFOLLOW`. A
/// `flock` belongs to the open file description, so it holds between two
/// calls in one server and between servers: each Claude session runs its
/// own `CheSlackMCP` process. che-telegram-all-mcp takes the same kind of
/// `flock`, on a `.archive.lock` file it creates in the chat directory and
/// leaves there; locking the directory leaves no file behind, so the
/// conversation directory holds only day files and the manifest.
///
/// Safe defaults:
/// - The lock is held only inside `holding`, which releases it however the
///   body ends: a result, a thrown error, a cancellation. The kernel drops
///   it when the process dies, so a crash leaves no stale lock.
/// - Taking the lock needs the directory, so missing ones are created
///   (0700). On release, those still empty, because the run wrote nothing,
///   are removed, before the descriptor is closed; a call that locked a
///   directory just removed sees that its path no longer names it and
///   takes the lock again.
/// - A refused call creates nothing: the directory exists while another run
///   holds it. Directories created by a call that failed to lock for
///   another reason are left, since another run may be using them.
/// - A file system without `flock` refuses the call rather than archiving
///   unlocked.
struct ArchiveLock {
    /// Attempts at locking a directory that finishing runs keep removing.
    static let maxAttempts = 3

    private let descriptor: Int32
    /// The directories `acquire` created, outermost first.
    private let created: [URL]

    /// Runs `body` with the lock on `directory` held, and releases it on
    /// every way out of `body`.
    static func holding<T>(_ directory: ArchiveDirectory, _ body: () async throws -> T) async throws -> T {
        let lock = try acquire(directory)
        defer { lock.release() }
        return try await body()
    }

    private static func acquire(_ directory: ArchiveDirectory) throws(ToolFailure) -> ArchiveLock {
        let path = directory.conversationDir.path
        var created: [URL] = []
        for attempt in 1...maxAttempts {
            do throws(ToolFailure) {
                created += try directory.createDirectories()
            } catch {
                // A parent another run's release removed meanwhile.
                if attempt < maxAttempts { continue }
                throw error
            }
            let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }   // removed by a run that just ended
                throw failure(directory, errno)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(descriptor)
                throw code == EWOULDBLOCK ? busy(directory) : failure(directory, code)
            }
            if names(descriptor, path) { return ArchiveLock(descriptor: descriptor, created: created) }
            close(descriptor)   // a directory a run that just ended had removed
        }
        throw ToolFailure("Could not lock \(path): other archive runs kept removing it. Nothing was archived; "
                          + "try again.")
    }

    /// Removes the directories `acquire` created that are still empty,
    /// innermost first (`rmdir` leaves any other), then closes the
    /// descriptor, which drops the lock. An empty directory that cannot be
    /// removed is left; it holds nothing.
    private func release() {
        for directory in created.reversed() { rmdir(directory.path) }
        close(descriptor)
    }

    /// Whether `path` still names the directory `descriptor` has open.
    private static func names(_ descriptor: Int32, _ path: String) -> Bool {
        var held = stat()
        var named = stat()
        return fstat(descriptor, &held) == 0 && lstat(path, &named) == 0
            && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    private static func busy(_ directory: ArchiveDirectory) -> ToolFailure {
        ToolFailure("Another archive of conversation \(directory.conversationID) of workspace \(directory.teamID) "
                    + "into \(directory.outputDir.path) is running. Nothing was written; try again when it has "
                    + "finished.")
    }

    private static func failure(_ directory: ArchiveDirectory, _ code: Int32) -> ToolFailure {
        let hint = code == ENOTSUP || code == EOPNOTSUPP
            ? " The file system of output_dir does not support locks; choose an output_dir on a local disk." : ""
        return ToolFailure("Could not lock \(directory.conversationDir.path) against another archive of the same "
                           + "conversation: \(String(cString: strerror(code))). Nothing was archived.\(hint)")
    }
}
