import Foundation

/// A TDLib instance that can be asked to close.
public protocol TDLibClosable: AnyObject {
    /// Asks TDLib to close and waits for `authorizationStateClosed`; returns
    /// false if TDLib has not reported it within `timeout` seconds.
    func close(timeout: TimeInterval) async -> Bool
}

/// Opens TDLib on first use and closes it after an idle period
/// (PsychQuant/che-msg#58).
///
/// The first caller to need TDLib takes the `TDLibProcessLock` and opens a
/// client; later callers share it. When no call has used TDLib for the idle
/// timeout, `checkIdle` closes it and releases the lock, but only after TDLib
/// reports `authorizationStateClosed`; a close that does not finish within 30
/// seconds keeps the lock and is retried at the next idle check.
public actor TDLibLifecycle<Client: TDLibClosable> {
    public enum AccessError: Error, Equatable {
        /// Another process holds TDLib; `pid` is nil when it is not recorded.
        case heldByAnotherProcess(pid: Int32?)
    }

    /// How long a close may take before the lock is kept and the close retried.
    public static var closeTimeout: TimeInterval { 30 }

    private enum State {
        case closed
        case opening(Task<Client, Error>)
        case open(Client)
        case closing(Task<Bool, Never>, Client)
    }

    private let lock: TDLibProcessLock
    private let idleTimeout: TimeInterval?
    private let clock: @Sendable () -> TimeInterval
    private let log: @Sendable (String) -> Void
    private let open: @Sendable () async throws -> Client
    private var state: State = .closed
    private var lastUse: TimeInterval = 0
    private var closePending = false

    /// - Parameters:
    ///   - idleTimeout: seconds without a call before TDLib is closed; nil never closes.
    ///   - clock: monotonic seconds.
    ///   - log: receives the line written when a close does not finish.
    ///   - open: creates the TDLib client.
    public init(lock: TDLibProcessLock, idleTimeout: TimeInterval?,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                log: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) },
                open: @escaping @Sendable () async throws -> Client) {
        self.lock = lock
        self.idleTimeout = idleTimeout
        self.clock = clock
        self.log = log
        self.open = open
    }

    /// Whether a TDLib client exists in this process.
    public var isOpen: Bool {
        switch state {
        case .open, .closing: return true
        case .closed, .opening: return false
        }
    }

    /// The TDLib client, opened if needed. Throws `heldByAnotherProcess`
    /// without opening anything when another process holds TDLib.
    public func client() async throws -> Client {
        while true {
            switch state {
            case .open(let client):
                lastUse = clock()
                return client
            case .opening(let task):
                let client = try await task.value
                lastUse = clock()
                return client
            case .closing(let task, let client):
                settleClose(await task.value, client: client)
            case .closed:
                if case .heldBy(let pid) = lock.acquire() { throw AccessError.heldByAnotherProcess(pid: pid) }
                let task = Task { try await open() }
                state = .opening(task)
                do {
                    let client = try await task.value
                    state = .open(client)
                    lastUse = clock()
                    return client
                } catch {
                    state = .closed
                    lock.release()
                    throw error
                }
            }
        }
    }

    /// Closes TDLib and releases the lock when it has been idle for the
    /// timeout, or retries a close that did not finish last time.
    public func checkIdle() async {
        guard let idleTimeout, case .open(let client) = state,
              closePending || clock() - lastUse >= idleTimeout else { return }
        let task = Task { await client.close(timeout: Self.closeTimeout) }
        state = .closing(task, client)
        settleClose(await task.value, client: client)
    }

    /// Closes TDLib, if this process has it open or is opening it, and
    /// releases the lock. The server awaits this before it exits, so TDLib
    /// never shuts down concurrently with the process's own teardown (a close
    /// racing process exit crashed TDLib in `Td::clear`). A close that does
    /// not finish is not retried; the kernel drops the flock at exit.
    public func shutdown() async {
        while true {
            switch state {
            case .closed:
                return
            case .opening(let task):
                _ = try? await task.value
                await Task.yield()   // let the opener record the result
            case .closing(let task, let client):
                settleClose(await task.value, client: client)
                if case .open = state { return }
            case .open(let client):
                let task = Task { await client.close(timeout: Self.closeTimeout) }
                state = .closing(task, client)
                settleClose(await task.value, client: client)
                return
            }
        }
    }

    /// Applies a finished close; whichever of `checkIdle` and `client` sees it
    /// first does so, the other finds the state already settled.
    private func settleClose(_ closed: Bool, client: Client) {
        guard case .closing(_, let closing) = state, closing === client else { return }
        if closed {
            state = .closed
            closePending = false
            lock.release()
        } else {
            state = .open(client)
            closePending = true
            log("che-telegram-all-mcp: TDLib did not report authorizationStateClosed within "
                + "\(Int(Self.closeTimeout)) s; keeping the TDLib lock and retrying at the next idle check")
        }
    }
}

/// `CHE_TELEGRAM_ALL_IDLE_TIMEOUT`: whole seconds before an idle TDLib closes.
public enum IdleTimeout {
    public static let environmentVariable = "CHE_TELEGRAM_ALL_IDLE_TIMEOUT"
    public static let defaultSeconds: TimeInterval = 600

    /// The idle timeout for `value`, or nil when idle closing is disabled
    /// (`0`). Unset or empty means the default; any other value that is not a
    /// whole number of seconds at least 0 means the default plus one warning.
    public static func parse(_ value: String?, warn: (String) -> Void) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return defaultSeconds }
        guard let seconds = Int(raw), seconds >= 0 else {
            warn("che-telegram-all-mcp: ignoring \(environmentVariable)=\(raw) (expected whole seconds, 0 or more); "
                 + "using \(Int(defaultSeconds))")
            return defaultSeconds
        }
        return seconds == 0 ? nil : TimeInterval(seconds)
    }

    /// `parse` applied to the process environment, warnings to stderr.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval? {
        parse(environment[environmentVariable], warn: { fputs($0 + "\n", stderr) })
    }
}
