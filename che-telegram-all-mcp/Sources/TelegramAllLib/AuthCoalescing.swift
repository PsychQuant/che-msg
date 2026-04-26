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

    defer { holder.clearIfMatches(task) }
    try await task.value
}
