import Foundation

/// TDLib for one `telegram-all` command (PsychQuant/che-msg#61).
///
/// The CLI takes the same `TDLibProcessLock` as the server before it opens
/// TDLib, so a CLI command and a session never run on one database (and one
/// auth key) at once. While another process holds TDLib the command opens
/// nothing and names the holder.
public enum TDLibCommandSession {
    /// Thrown by `run` when another process holds TDLib; nothing was opened.
    public struct Held: Error, Equatable {
        /// `heldMessage` for the holder.
        public let message: String
    }

    /// The line `telegram-all` prints when another process holds TDLib.
    public static func heldMessage(holderPid: Int32?) -> String {
        let holder = holderPid.map { "process \($0)" } ?? "another process (unknown holder)"
        return "telegram-all: TDLib is in use by \(holder), so this command did not open it. "
            + "A Claude Code session closes TDLib after it has been idle for its idle timeout "
            + "(\(IdleTimeout.environmentVariable), \(Int(IdleTimeout.defaultSeconds)) seconds by default); "
            + "try again then."
    }

    /// Takes `lock`: nil when this process now holds it, otherwise the
    /// message naming the process that does.
    public static func acquire(_ lock: TDLibProcessLock) -> String? {
        if case .heldBy(let pid) = lock.acquire() { return heldMessage(holderPid: pid) }
        return nil
    }

    /// Takes `lock`, opens TDLib with `open`, and runs `body` with it. Then
    /// closes TDLib and only after that releases the lock, whether `body`
    /// returned or threw; the lock is not left to `deinit` order, since Swift
    /// can release a local before the end of its scope. A close that does not
    /// finish within 30 s keeps the lock until the process exits (the kernel
    /// drops the flock then), so no other process opens TDLib while this one
    /// may still be running it. Throws `Held` without opening anything when
    /// another process holds TDLib.
    public static func run<Client: TDLibClosable, T>(
        lock: TDLibProcessLock,
        log: (String) -> Void = { fputs($0 + "\n", stderr) },
        open: () async throws -> Client,
        body: (Client) async throws -> T
    ) async throws -> T {
        if let message = acquire(lock) { throw Held(message: message) }
        let client: Client
        do {
            client = try await open()
        } catch {
            lock.release()
            throw error
        }
        let result: Result<T, Error>
        do {
            result = .success(try await body(client))
        } catch {
            result = .failure(error)
        }
        let timeout = TDLibLifecycle<Client>.closeTimeout
        if await client.close(timeout: timeout) {
            lock.release()
        } else {
            log("telegram-all: TDLib did not report authorizationStateClosed within \(Int(timeout)) s; "
                + "keeping the TDLib lock until telegram-all exits")
            // Never released: the lock's deinit would release it otherwise.
            _ = Unmanaged.passRetained(lock)
        }
        return try result.get()
    }
}
