import Foundation

/// `operation`'s result, or nil when it has not finished within `seconds`.
/// For tests whose failure mode is waiting forever (for example an answer lost
/// before anything waits for it): they fail instead of hanging the suite. The
/// operation keeps running after a timeout.
func finished<T: Sendable>(within seconds: TimeInterval,
                           _ operation: @escaping @Sendable () async -> T) async -> T? {
    let first = FirstResult<T>()
    return await withCheckedContinuation { continuation in
        first.wait(with: continuation)
        Task { first.offer(await operation()) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            first.offer(nil)
        }
    }
}

/// Resumes its continuation with the first value offered and ignores the rest.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func wait(with continuation: CheckedContinuation<T?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func offer(_ value: T?) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
