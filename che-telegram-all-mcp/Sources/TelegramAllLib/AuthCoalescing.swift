import Foundation
import os

/// Holds a single optional `Task<Void, Error>` reference, lock-protected,
/// for the Coalesced Task pattern.
///
/// Each authentication method (`setParameters`, `sendPhoneNumber`,
/// `sendAuthCode`, `sendPassword`) owns one `TaskFieldHolder` that tracks
/// the in-flight call. Concurrent callers see the same task and await its
/// outcome rather than issuing duplicate TDLib requests.
///
/// `OSAllocatedUnfairLock` is non-reentrant; the critical section MUST NOT
/// suspend. Holders use the lock only for atomic compare-and-swap on the
/// `task` field.
internal final class TaskFieldHolder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var task: Task<Void, Error>?

    init() {}

    /// Returns the current task without claiming the slot.
    func current() -> Task<Void, Error>? {
        lock.withLock { task }
    }

    /// Atomically:
    /// - If `task` is non-nil, returns it (caller awaits the existing one).
    /// - Otherwise, calls `make()` to create a fresh task, stores it, and
    ///   returns it. Wraps `make()` to clear the field after completion
    ///   so the next caller starts a new run.
    func acquireOrCreate(_ make: () -> Task<Void, Error>) -> Task<Void, Error> {
        lock.withLock {
            if let existing = task { return existing }
            let fresh = make()
            task = fresh
            return fresh
        }
    }

    /// Clears the task slot if it matches the given task. Used by the
    /// `coalesceTask` helper after the body completes (success or failure).
    /// The match check prevents a stale clear from blowing away a newer
    /// in-flight task.
    func clearIfMatches(_ done: Task<Void, Error>) {
        lock.withLock {
            if task == done { task = nil }
        }
    }
}

/// Coalesces concurrent invocations sharing a `TaskFieldHolder`: if a body
/// is already in flight, awaits its outcome; otherwise spawns a fresh task,
/// awaits it, and clears the slot.
///
/// All callers (success or failure) observe the same outcome from the
/// shared task — proving the coalescing contract.
///
/// - Parameters:
///   - holder: The `TaskFieldHolder` tracking the method's in-flight task.
///   - body: The async work to coalesce. Runs at most once across concurrent
///     callers sharing the same holder.
/// - Throws: Whatever `body` throws — propagated identically to all callers.
internal func coalesceTask(
    holder: TaskFieldHolder,
    body: @escaping @Sendable () async throws -> Void
) async throws {
    // Note: We can't call body directly inside `acquireOrCreate` because
    // that closure is sync. Build the Task lazily and let the lock-CAS
    // decide whether to keep it or use the existing one.
    let task = holder.acquireOrCreate {
        Task { try await body() }
    }
    try await awaitCoalesced(task, holder: holder)
}

/// Awaits a coalesced task and then frees its slot, so the next caller starts
/// a new run.
internal func awaitCoalesced(_ task: Task<Void, Error>, holder: TaskFieldHolder) async throws {
    defer { holder.clearIfMatches(task) }
    try await task.value
}

/// The coalesced form of a request that is handed to TDLib at the moment its
/// task is created (PsychQuant/che-msg#98): if a task is in flight, returns it;
/// otherwise calls `send` right away, synchronously, and returns a task that
/// waits for the answer `send` delivers. Never suspends, so a caller can hold
/// a lock that orders the request against other events; `send` and the answer
/// it delivers must not take that lock or `holder`'s. Await the task with
/// `awaitCoalesced`.
internal func coalescedRequest(
    holder: TaskFieldHolder,
    send: (_ deliver: @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
) -> Task<Void, Error> {
    holder.acquireOrCreate {
        let answer = RequestAnswer()
        send { answer.deliver($0) }
        return Task { try await answer.value() }
    }
}

/// The one answer to a request handed over before anything waits for it: it
/// may arrive before the waiting task starts, or even while the request is
/// being handed over. Only the first delivery counts.
internal final class RequestAnswer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func deliver(_ answer: Result<Void, Error>) {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = answer
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: answer)
    }

    /// Waits for the answer; call it once.
    func value() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready: Result<Void, Error>? = lock.withLock {
                if result == nil { waiter = continuation }
                return result
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
