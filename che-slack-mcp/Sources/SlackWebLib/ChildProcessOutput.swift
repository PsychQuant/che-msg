import Foundation

/// How a child process ended, as far as a bounded lookup is concerned.
enum ChildOutcome: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case couldNotStart
}

/// Collects a child's output in the background, up to `limit` bytes, so the
/// child never blocks on a full pipe and the caller never blocks on EOF.
final class OutputCollector: @unchecked Sendable {
    static let limit = 64 * 1024
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd = false
    private var truncated = false

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            guard let self else { return }
            self.lock.withLock {
                if chunk.isEmpty {
                    self.reachedEnd = true
                } else {
                    let room = Self.limit - self.data.count
                    if chunk.count > room { self.truncated = true }
                    if room > 0 { self.data.append(chunk.prefix(room)) }
                }
            }
            if chunk.isEmpty { readable.readabilityHandler = nil }
        }
    }

    /// Waits up to `seconds` for EOF, then stops reading and returns what
    /// arrived, and whether more than `limit` bytes were written.
    func finish(waitingUpTo seconds: TimeInterval) async -> (data: Data, truncated: Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ reachedEnd }), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        handle.readabilityHandler = nil
        try? handle.close()
        return lock.withLock { (data, truncated) }
    }
}

/// Resumes a continuation once, whichever of exit and timeout comes first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChildOutcome, Never>?

    init(_ continuation: CheckedContinuation<ChildOutcome, Never>) { self.continuation = continuation }

    func resume(_ outcome: ChildOutcome) {
        let pending: CheckedContinuation<ChildOutcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: outcome)
    }
}
