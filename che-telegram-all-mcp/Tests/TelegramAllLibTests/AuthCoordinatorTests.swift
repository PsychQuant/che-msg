import XCTest
@testable import TelegramAllLib

/// The automatic phone number and 2FA password against state changes and
/// explicit calls, on the production path with TDLib replaced by a fake
/// sender (PsychQuant/che-msg#98).
///
/// Spec: "An automatic credential is claimed and handed to TDLib in one step"
/// (telegram-auth-coordination). `afterAutomaticClaim` runs as soon as the
/// claim step returns, the first moment another caller can take the lock, so
/// what a test does there is what a concurrent caller could do at the worst
/// moment.
final class AuthCoordinatorTests: XCTestCase {
    // MARK: - Fakes

    /// Records every request handed over, with the authorization generation
    /// current at the end of the hand-off, and answers it at once
    /// (asynchronously, like TDLibKit); with `holdFirst`, the first request is
    /// answered only when the test says.
    private final class FakeRequests: CredentialRequestSending, @unchecked Sendable {
        struct HandOff: Equatable {
            let method: String
            let value: String
            let generation: UInt64
        }

        private let lock = NSLock()
        private var handOffList: [HandOff] = []
        private var completions: [@Sendable (Result<Void, Swift.Error>) -> Void] = []
        private let answer: Result<Void, Swift.Error>
        private let holdFirst: Bool
        /// Where the generation is read; set once the coordinator exists.
        var tracker: CredentialLookupTracker?
        /// Runs inside the hand-off, before it ends.
        var duringHandOff: (@Sendable () -> Void)?

        init(answer: Result<Void, Swift.Error>, holdFirst: Bool = false) {
            self.answer = answer
            self.holdFirst = holdFirst
        }

        func setAuthenticationPhoneNumber(_ phoneNumber: String,
                                          completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void) {
            handOff("phone", phoneNumber, completion)
        }

        func checkAuthenticationPassword(_ password: String,
                                         completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void) {
            handOff("password", password, completion)
        }

        private func handOff(_ method: String, _ value: String,
                             _ completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void) {
            duringHandOff?()
            let generation = tracker?.generationNow ?? 0
            let held: Bool = lock.withLock {
                handOffList.append(HandOff(method: method, value: value, generation: generation))
                completions.append(completion)
                return holdFirst && handOffList.count == 1
            }
            if !held { DispatchQueue.global().async { [answer] in completion(answer) } }
        }

        var handOffs: [HandOff] { lock.withLock { handOffList } }

        func complete(_ index: Int, with result: Result<Void, Swift.Error>) {
            let completion = lock.withLock { completions[index] }
            completion(result)
        }

        func waitForHandOffs(_ count: Int) async {
            await waitUntil { self.handOffs.count >= count }
        }
    }

    /// A Keychain source whose lookup returns only when the test releases it.
    private final class GatedSource: KeychainCredentialSource, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<KeychainLookup, Never>?

        func lookup(_ credential: KeychainCredential) async -> KeychainLookup {
            await withCheckedContinuation { continuation in lock.withLock { pending = continuation } }
        }

        func waitUntilAsked() async { await waitUntil { self.lock.withLock { self.pending != nil } } }

        func release(_ result: KeychainLookup) {
            let continuation = lock.withLock {
                defer { pending = nil }
                return pending
            }
            continuation?.resume(returning: result)
        }
    }

    private struct FoundSource: KeychainCredentialSource {
        let value: String
        func lookup(_ credential: KeychainCredential) async -> KeychainLookup { .found(value) }
    }

    /// Lets a hook reach the coordinator it is passed to.
    private final class Box: @unchecked Sendable {
        weak var coordinator: AuthCoordinator?
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Swift.Error?] = []
        func record(_ error: Swift.Error?) { lock.withLock { stored.append(error) } }
        var errors: [Swift.Error?] { lock.withLock { stored } }
    }

    private static let rejected = TDLibClient.TDError.tdlibError(code: 400, message: "PASSWORD_HASH_INVALID")

    private static func isRejected(_ error: Swift.Error?) -> Bool {
        guard case .tdlibError(400, "PASSWORD_HASH_INVALID")? = error as? TDLibClient.TDError else { return false }
        return true
    }

    // MARK: - A state change and the automatic value (#98 window 1)

    /// Scenario: a state change right after the claim finds the request
    /// already handed over.
    func testAStateChangeRightAfterTheClaimFindsTheRequestAlreadyHandedOver() async {
        let cases: [(TDLibClient.AuthState, CredentialPlan, next: TDLibClient.AuthState)] = [
            (.waitingForPhoneNumber, .fire("+886900000417"), .waitingForCode),
            (.waitingForPassword, .fire("stored-secret"), .ready),
        ]
        for (state, plan, next) in cases {
            let fake = FakeRequests(answer: .success(()))
            let box = Box()
            let coordinator = AuthCoordinator(credentials: NoKeychainCredentialSource(), requests: fake,
                                              afterAutomaticClaim: { box.coordinator?.enter(next) })
            box.coordinator = coordinator
            fake.tracker = coordinator.credentialLookups
            let generation = coordinator.credentialLookups.generationNow + 1
            await coordinator.enterCredentialState(state, plan: plan)?.value
            XCTAssertEqual(fake.handOffs.map(\.generation), [generation],
                           "\(state): the request is handed over while its state is still current, and once")
            XCTAssertEqual(coordinator.state, next)
        }
    }

    /// Scenario: a state change during the hand-off waits for it. Another
    /// thread records a state change while the request is being handed over
    /// and the hand-off waits up to 1 s for it; the state change can only land
    /// after the hand-off.
    func testAStateChangeDuringTheHandOffWaitsForIt() async {
        let fake = FakeRequests(answer: .success(()))
        let coordinator = AuthCoordinator(credentials: NoKeychainCredentialSource(), requests: fake)
        fake.tracker = coordinator.credentialLookups
        let recorded = DispatchSemaphore(value: 0)
        fake.duringHandOff = {
            DispatchQueue.global().async {
                coordinator.enter(.ready)
                recorded.signal()
            }
            _ = recorded.wait(timeout: .now() + 1)
        }
        let generation = coordinator.credentialLookups.generationNow + 1
        await coordinator.enterCredentialState(.waitingForPassword, plan: .fire("stored-secret"))?.value
        XCTAssertEqual(fake.handOffs.map(\.generation), [generation],
                       "the state change was recorded only after the request was handed over")
        await waitUntil { coordinator.state == .ready }
        XCTAssertEqual(coordinator.state, .ready)
    }

    /// Scenario: a state change before the claim sends nothing.
    func testAStateChangeBeforeTheClaimSendsNothing() async {
        let fake = FakeRequests(answer: .success(()))
        let source = GatedSource()
        let coordinator = AuthCoordinator(credentials: source, requests: fake)
        let automatic = coordinator.enterCredentialState(.waitingForPassword, plan: .lookUp(.password))
        await source.waitUntilAsked()
        coordinator.enter(.ready)
        source.release(.found("stored-secret"))
        await automatic?.value
        XCTAssertEqual(fake.handOffs, [], "the value belongs to a state that is gone")
    }

    // MARK: - An explicit call and the automatic value (#98 window 2)

    /// Scenario: an explicit call after the claim joins the automatic request.
    /// TDLib receives only the automatic request; the explicit caller gets its
    /// answer.
    func testAnExplicitCallAfterTheClaimJoinsTheAutomaticRequest() async {
        let cases: [(TDLibClient.AuthState, CredentialPlan, KeychainCredentialSource, method: String,
                     automatic: String, explicit: String)] = [
            (.waitingForPhoneNumber, .fire("+886900000417"), NoKeychainCredentialSource(), "phone",
             "+886900000417", "+886911111111"),
            (.waitingForPassword, .lookUp(.password), FoundSource(value: "stored-secret"), "password",
             "stored-secret", "typed-secret"),
        ]
        for (state, plan, source, method, automatic, explicit) in cases {
            let fake = FakeRequests(answer: .failure(Self.rejected))
            let box = Box()
            let outcome = Outcome()
            let coordinator = AuthCoordinator(credentials: source, requests: fake, afterAutomaticClaim: {
                guard let coordinator = box.coordinator else { return }
                do {
                    if method == "phone" { try await coordinator.sendPhoneNumber(explicit) }
                    else { try await coordinator.sendPassword(explicit) }
                    outcome.record(nil)
                } catch {
                    outcome.record(error)
                }
            })
            box.coordinator = coordinator
            await coordinator.enterCredentialState(state, plan: plan)?.value
            XCTAssertEqual(fake.handOffs.map(\.value), [automatic], "\(method): one request, the automatic one")
            XCTAssertEqual(outcome.errors.count, 1)
            XCTAssertTrue(Self.isRejected(outcome.errors.first ?? nil),
                          "\(method): the explicit caller gets the automatic request's answer")
            XCTAssertTrue(Self.isRejected(coordinator.lastAutoFireError), "\(method): recorded for auth_status")
        }
    }

    // MARK: - Explicit values before the claim (#96)

    func testAnExplicitValueBeforeTheClaimSendsNoAutomaticOne() async throws {
        let fake = FakeRequests(answer: .success(()))
        let source = GatedSource()
        let coordinator = AuthCoordinator(credentials: source, requests: fake)
        let automatic = coordinator.enterCredentialState(.waitingForPassword, plan: .lookUp(.password))
        await source.waitUntilAsked()
        try await coordinator.sendPassword("typed-secret")
        source.release(.found("stored-secret"))
        await automatic?.value
        XCTAssertEqual(fake.handOffs.map(\.value), ["typed-secret"])
        XCTAssertFalse(coordinator.isSubmittingKeychainCredential,
                       "nothing from the Keychain is on its way, so auth_run does not wait for it")
    }

    func testAnExplicitValueForAnotherStepDoesNotCancelThisStepsAutomaticOne() async throws {
        let fake = FakeRequests(answer: .success(()))
        let source = GatedSource()
        let coordinator = AuthCoordinator(credentials: source, requests: fake)
        let automatic = coordinator.enterCredentialState(.waitingForPassword, plan: .lookUp(.password))
        await source.waitUntilAsked()
        try await coordinator.sendPhoneNumber("+886911111111")
        source.release(.found("stored-secret"))
        await automatic?.value
        XCTAssertEqual(fake.handOffs.map(\.method), ["phone", "password"])
        XCTAssertEqual(fake.handOffs.map(\.value), ["+886911111111", "stored-secret"])
    }

    // MARK: - A newer state and a request still in flight (#98 comment 1)

    /// Option B keeps coalescing per method: a newer state's automatic value
    /// joins the same method's request that an earlier state handed over and
    /// TDLib has not answered yet, and sends none of its own (same value from
    /// the same source; design: Non-Goals). Deterministic once the claim and
    /// the join are one step.
    func testANewerStateJoinsTheSameMethodsRequestStillInFlight() async {
        let fake = FakeRequests(answer: .success(()), holdFirst: true)
        let claims = Outcome()
        let coordinator = AuthCoordinator(credentials: NoKeychainCredentialSource(), requests: fake,
                                          afterAutomaticClaim: { claims.record(nil) })
        let first = coordinator.enterCredentialState(.waitingForPhoneNumber, plan: .fire("+886900000417"))
        await fake.waitForHandOffs(1)
        coordinator.enter(.waitingForCode)
        let second = coordinator.enterCredentialState(.waitingForPhoneNumber, plan: .fire("+886900000417"))
        await waitUntil { claims.errors.count == 2 }
        fake.complete(0, with: .success(()))
        await first?.value
        await second?.value
        XCTAssertEqual(fake.handOffs.count, 1)
    }
}

/// Polls `condition` every millisecond for up to 5 seconds.
private func waitUntil(_ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
