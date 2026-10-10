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
/// 120 seconds every time TDLib is reopened.
public final class TDLibSyncState: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        /// The latest connection state TDLib reported since it was opened,
        /// e.g. `connectionStateUpdating`; nil when none, or TDLib is closed.
        public let connectionState: String?
        public let isSynced: Bool
        public let unsyncedSeconds: Int

        public init(connectionState: String?, isSynced: Bool, unsyncedSeconds: Int) {
            self.connectionState = connectionState
            self.isSynced = isSynced
            self.unsyncedSeconds = unsyncedSeconds
        }
    }

    public static let readyState = "connectionStateReady"
    /// Unsynced seconds after which the session is reported as stalled.
    public static let stallThreshold = 120

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var connectionState: String?
    private var isOpen = false
    /// Unsynced time from earlier open periods, since TDLib was last synced.
    private var accumulated: TimeInterval = 0
    /// Start of the current open, unsynced period; nil when synced or closed.
    private var segmentStart: TimeInterval?

    public init(clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    /// TDLib was opened; it is not synced until it reports `connectionStateReady`.
    public func tdlibOpened() {
        lock.withLock {
            isOpen = true
            connectionState = nil
            if segmentStart == nil { segmentStart = clock() }
        }
    }

    /// TDLib was closed; its unsynced time so far is kept.
    public func tdlibClosed() {
        lock.withLock {
            if let start = segmentStart { accumulated += clock() - start }
            segmentStart = nil
            isOpen = false
            connectionState = nil
        }
    }

    /// Records a connection state TDLib reported (the `ConnectionState` case
    /// name, e.g. `connectionStateUpdating`).
    public func record(_ state: String) {
        lock.withLock {
            guard isOpen else { return }
            connectionState = state
            if state == Self.readyState {
                accumulated = 0
                segmentStart = nil
            } else if segmentStart == nil {
                segmentStart = clock()
            }
        }
    }

    /// Forgets the unsynced time after a logout: a new session starts at 0.
    public func reset() {
        lock.withLock {
            accumulated = 0
            segmentStart = isOpen ? clock() : nil
        }
    }

    public var snapshot: Snapshot {
        lock.withLock {
            var unsynced = accumulated
            if let start = segmentStart { unsynced += clock() - start }
            return Snapshot(connectionState: connectionState,
                            isSynced: isOpen && connectionState == Self.readyState,
                            unsyncedSeconds: Int(unsynced.rounded(.down)))
        }
    }

    public func isStalled(threshold: Int = TDLibSyncState.stallThreshold) -> Bool {
        snapshot.unsyncedSeconds >= threshold
    }
}
