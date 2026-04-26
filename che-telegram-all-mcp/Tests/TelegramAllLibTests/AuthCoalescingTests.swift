import XCTest
@testable import TelegramAllLib

/// Covers spec requirement: "Coalesced execution of authentication methods"
/// Corresponds to design Decision 2: Coalesced Task pattern — pure helper at file scope.
///
/// Tests target the file-scope helper `coalesceTask(holder:body:)` and its
/// supporting `TaskFieldHolder` class. No `TDLibClient` instantiation —
/// TDLib's receive loop is process-global, so concurrency contracts are
/// verified on the pure helper instead.
final class AuthCoalescingTests: XCTestCase {

    // MARK: - Coalesced execution: body runs at most once

    func testTwoConcurrentCallersShareSingleBodyExecution() async throws {
        let holder = TaskFieldHolder()
        let counter = Counter()

        async let a: Void = coalesceTask(holder: holder) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — wide enough race window
        }
        async let b: Void = coalesceTask(holder: holder) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        _ = try await (a, b)

        let count = await counter.value
        XCTAssertEqual(count, 1,
                       "Coalesced caller body MUST run exactly once, not once per caller")
    }

    func testThreeConcurrentCallersShareSingleBodyExecution() async throws {
        let holder = TaskFieldHolder()
        let counter = Counter()

        async let a: Void = coalesceTask(holder: holder) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        async let b: Void = coalesceTask(holder: holder) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        async let c: Void = coalesceTask(holder: holder) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        _ = try await (a, b, c)

        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    // MARK: - Coalesced callers all observe same outcome

    func testAllCoalescedCallersObserveSameSuccess() async throws {
        let holder = TaskFieldHolder()

        async let a: Void = coalesceTask(holder: holder) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            // body succeeds
        }
        async let b: Void = coalesceTask(holder: holder) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // Both must succeed (no throw)
        _ = try await (a, b)
    }

    func testAllCoalescedCallersObserveSameFailure() async throws {
        struct TestError: Swift.Error, Equatable {
            let id: Int
        }

        let holder = TaskFieldHolder()
        let counter = Counter()

        // Use Result wrappers to capture outcomes from both callers.
        async let aResult: Result<Void, Error> = await Result {
            try await coalesceTask(holder: holder) {
                await counter.increment()
                try? await Task.sleep(nanoseconds: 20_000_000)
                throw TestError(id: 42)
            }
        }
        async let bResult: Result<Void, Error> = await Result {
            try await coalesceTask(holder: holder) {
                await counter.increment()
                try? await Task.sleep(nanoseconds: 20_000_000)
                throw TestError(id: 99) // never runs — second caller awaits first's body
            }
        }

        let a = await aResult
        let b = await bResult

        // Both must fail with the SAME error — proving they shared the in-flight task.
        // Whichever body wins the lock race (42 or 99) is the body that runs;
        // both callers MUST observe that winner identically. Coalescing is about
        // sharing the outcome, not about which caller's body ran.
        let aId: Int? = {
            if case .failure(let e) = a, let te = e as? TestError { return te.id }
            return nil
        }()
        let bId: Int? = {
            if case .failure(let e) = b, let te = e as? TestError { return te.id }
            return nil
        }()
        XCTAssertNotNil(aId, "A MUST fail with TestError")
        XCTAssertNotNil(bId, "B MUST fail with TestError")
        XCTAssertEqual(aId, bId,
                       "A and B MUST observe the SAME error from the coalesced body")
        XCTAssertTrue(aId == 42 || aId == 99,
                      "Observed id MUST be one of the two body candidates")

        let count = await counter.value
        XCTAssertEqual(count, 1, "Body MUST execute only once even when it throws")
    }

    // MARK: - Coalesce window ends after task completes

    func testNewCallerAfterCompletionReceivesNewExecution() async throws {
        let holder = TaskFieldHolder()
        let counter = Counter()

        // Caller A — runs body once and completes.
        try await coalesceTask(holder: holder) {
            await counter.increment()
        }

        // Caller B — fresh call after A completed; body MUST run again.
        try await coalesceTask(holder: holder) {
            await counter.increment()
        }

        let count = await counter.value
        XCTAssertEqual(count, 2,
                       "After in-flight task completes, a fresh caller MUST trigger a new body execution")
    }

    // MARK: - Coalescing covers auto-fire vs manual-path scenario

    func testAutoFireAndManualCallerCoalesce() async throws {
        // Mimic the realistic race: an auto-fire path (faster scheduling) and
        // a manual MCP caller arriving in the same window. They both target
        // the same TaskFieldHolder (representing the `setParametersTask` field
        // that TDLibClient will own). Body must run once.
        let holder = TaskFieldHolder()
        let counter = Counter()

        async let autoFire: Void = coalesceTask(holder: holder) {
            try? await Task.sleep(nanoseconds: 40_000_000) // simulate TDLib roundtrip
            await counter.increment()
        }
        // 5ms delay to simulate manual caller arriving slightly later, while
        // the auto-fire body is in flight.
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let manualCall: Void = coalesceTask(holder: holder) {
            try? await Task.sleep(nanoseconds: 40_000_000)
            await counter.increment()
        }

        _ = try await (autoFire, manualCall)

        let count = await counter.value
        XCTAssertEqual(count, 1,
                       "Auto-fire and manual caller MUST coalesce — only one TDLib roundtrip")
    }
}

// MARK: - Test helpers

/// Async-safe counter for verifying coalesced body execution count.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Bridges async throwing closures to Result for test assertions.
private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) }
        catch { self = .failure(error) }
    }
}
