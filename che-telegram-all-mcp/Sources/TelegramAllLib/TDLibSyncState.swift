import Foundation

/// Whether TDLib is synced with Telegram (PsychQuant/che-msg#63).
///
/// TDLib can stay `authorizationStateReady` while it never syncs: when
/// Telegram invalidates the session, every `getDifference` fails inside TDLib
/// and the client only sees the connection state stuck short of
/// `connectionStateReady`. This records the states TDLib reports and how long
/// TDLib has been open since it was last synced. It reads no error messages
/// (code 406 stays silent, as `telegram-auth-error-reporting` requires).
///
/// The unsynced duration counts only time TDLib is open, and it survives an
/// idle close: a session that never syncs must not look healthy for another
/// 120 seconds every time TDLib is reopened. Only time spent updating can make
/// the session stalled; time without a network never does.
public final class TDLibSyncState: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        /// The latest connection state TDLib reported since it was opened,
        /// e.g. `connectionStateUpdating`; nil when none, or TDLib is closed.
        public let connectionState: String?
        public let isSynced: Bool
        /// Seconds TDLib has been open since it was last synced.
        public let unsyncedSeconds: Int
        /// Of those, seconds TDLib spent in `connectionStateUpdating` — only
        /// these can make a session stalled; time offline never does.
        public let updatingSeconds: Int

        public init(connectionState: String?, isSynced: Bool, unsyncedSeconds: Int, updatingSeconds: Int = 0) {
            self.connectionState = connectionState
            self.isSynced = isSynced
            self.unsyncedSeconds = unsyncedSeconds
            self.updatingSeconds = updatingSeconds
        }

        /// Stalled: still catching up with Telegram after `threshold` seconds of
        /// updating. A session Telegram has invalidated stays here forever.
        public func isStalled(threshold: Int = TDLibSyncState.stallThreshold) -> Bool {
            connectionState == TDLibSyncState.updatingState && updatingSeconds >= threshold
        }
    }

    public static let readyState = "connectionStateReady"
    public static let updatingState = "connectionStateUpdating"
    /// Updating seconds after which the session is reported as stalled.
    public static let stallThreshold = 120

    /// A span of open time, accumulated across idle closes.
    private struct Counter {
        var accumulated: TimeInterval = 0
        var start: TimeInterval?
        mutating func begin(_ now: TimeInterval) { if start == nil { start = now } }
        mutating func end(_ now: TimeInterval) {
            if let start { accumulated += max(0, now - start) }
            start = nil
        }
        mutating func clear() { accumulated = 0; start = nil }
        func seconds(_ now: TimeInterval) -> Int {
            Int((accumulated + (start.map { max(0, now - $0) } ?? 0)).rounded(.down))
        }
    }

    private let lock = NSLock()
    /// Monotonic by default, so a change of the system time cannot make a
    /// duration negative or jump.
    private let clock: @Sendable () -> TimeInterval
    private var connectionState: String?
    private var isOpen = false
    private var unsynced = Counter()
    private var updating = Counter()

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// TDLib was opened; it is not synced until it reports `connectionStateReady`.
    public func tdlibOpened() {
        lock.withLock {
            isOpen = true
            connectionState = nil
            unsynced.begin(clock())
        }
    }

    /// TDLib was closed; its unsynced and updating time so far is kept.
    public func tdlibClosed() {
        lock.withLock {
            let now = clock()
            unsynced.end(now)
            updating.end(now)
            isOpen = false
            connectionState = nil
        }
    }

    /// Records a connection state TDLib reported (the `ConnectionState` case
    /// name, e.g. `connectionStateUpdating`).
    public func record(_ state: String) {
        lock.withLock {
            guard isOpen else { return }
            let now = clock()
            connectionState = state
            if state == Self.readyState {
                unsynced.clear()
                updating.clear()
                return
            }
            unsynced.begin(now)
            if state == Self.updatingState { updating.begin(now) } else { updating.end(now) }
        }
    }

    /// Forgets the unsynced and updating time after a logout: a new session
    /// starts at 0. Counting resumes only if TDLib is open and not synced.
    public func reset() {
        lock.withLock {
            let now = clock()
            unsynced.clear()
            updating.clear()
            guard isOpen, connectionState != Self.readyState else { return }
            unsynced.begin(now)
            if connectionState == Self.updatingState { updating.begin(now) }
        }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            let now = clock()
            return Snapshot(connectionState: connectionState,
                            isSynced: isOpen && connectionState == Self.readyState,
                            unsyncedSeconds: unsynced.seconds(now),
                            updatingSeconds: updating.seconds(now))
        }
    }

    public func isStalled(threshold: Int = TDLibSyncState.stallThreshold) -> Bool {
        snapshot.isStalled(threshold: threshold)
    }
}
