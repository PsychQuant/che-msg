import Foundation

// Shared with SlackAllCore (the `Slack Safe Storage` reader) at `package`
// access: callable from this package's targets, not part of the public API.

/// How a child process ended, as far as a bounded lookup is concerned.
package enum ChildOutcome: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case couldNotStart
}

/// Starts `process` and waits for it to exit or for `timeout` to pass,
/// whichever comes first; on timeout, terminates it and kills it if it is
/// still running `killGrace` seconds later. The caller sets up the child's
/// standard streams. Cancelling the calling task does not stop the child.
package func runBounded(_ process: Process, timeout: TimeInterval, killGrace: TimeInterval) async -> ChildOutcome {
    await withCheckedContinuation { (continuation: CheckedContinuation<ChildOutcome, Never>) in
        let once = ResumeOnce(continuation)
        process.terminationHandler = { finished in
            once.resume(.exited(finished.terminationStatus))
        }
        do {
            try process.run()
        } catch {
            once.resume(.couldNotStart)
            return
        }
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            // Resume first: once terminated, the exit handler would report
            // the signal's exit status instead of the timeout.
            once.resume(.timedOut)
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

/// Collects a child's output in the background, up to a byte limit, so the
/// child never blocks on a full pipe and the caller never blocks on EOF.
package final class OutputCollector: @unchecked Sendable {
    /// The default limit.
    package static let limit = 64 * 1024
    private let handle: FileHandle
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd = false
    private var truncated = false

    /// Starts reading `handle`, keeping at most `limit` bytes.
    package init(_ handle: FileHandle, limit: Int = OutputCollector.limit) {
        self.handle = handle
        self.maxBytes = limit
        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            guard let self else { return }
            self.lock.withLock {
                if chunk.isEmpty {
                    self.reachedEnd = true
                } else {
                    let room = self.maxBytes - self.data.count
                    if chunk.count > room { self.truncated = true }
                    if room > 0 { self.data.append(chunk.prefix(room)) }
                }
            }
            if chunk.isEmpty { readable.readabilityHandler = nil }
        }
    }

    /// Waits up to `seconds` for EOF, then stops reading and returns what
    /// arrived, and whether more than the limit was written. A cancelled
    /// task stops waiting at once and gets whatever has arrived so far.
    package func finish(waitingUpTo seconds: TimeInterval) async -> (data: Data, truncated: Bool) {
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
