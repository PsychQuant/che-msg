import Foundation

/// The client's source of time, injected so tests can run pacing and
/// rate-limit waits on virtual time.
public protocol SlackClock: Sendable {
    /// Time elapsed since an arbitrary fixed origin; only differences matter.
    func now() -> Duration
    /// Suspends for `duration`; throws `CancellationError` when cancelled.
    func sleep(for duration: Duration) async throws
}

/// The production clock, backed by `ContinuousClock`.
public struct SystemSlackClock: SlackClock {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public func now() -> Duration {
        ContinuousClock.now - origin
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
