import XCTest
import TDLibKit
@testable import TelegramAllLib

/// This file needs `TDLibKit.Error`; the client meant here is ours.
private typealias TDLibClient = TelegramAllLib.TDLibClient

/// The automatic phone number and 2FA password against state changes and
/// explicit calls, on the production path with TDLib replaced by a fake
/// sender (PsychQuant/che-msg#98).
///
/// Spec: "An automatic credential is claimed and handed to TDLib in one step"
/// (telegram-auth-coordination). `beforeAutomaticClaim` and
/// `afterAutomaticClaim` run right before and right after the claim step, the
/// last and the first moment another caller can take the lock, so what a test
/// does there is what a concurrent caller could do at the worst moment.
final class AuthCoordinatorTests: XCTestCase {
    // MARK: - Fakes

    /// Records every request handed over, with the authorization generation
    /// current at the end of the hand-off, and answers it at once
    /// (asynchronously, like TDLibKit); with `holdFirst`, the first request is
    /// answered only when the test says; with `inline`, inside the hand-off,
    /// as TDLibKit does when `send` throws.
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
        private let inline: Bool
        /// Where the generation is read; set once the coordinator exists.
        var tracker: CredentialLookupTracker?
        /// Runs inside the hand-off, before it ends.
        var duringHandOff: (@Sendable () -> Void)?

        init(answer: Result<Void, Swift.Error>, holdFirst: Bool = false, inline: Bool = false) {
            self.answer = answer
            self.holdFirst = holdFirst
            self.inline = inline
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
            if held { return }
            if inline { completion(answer) } else { DispatchQueue.global().async { [answer] in completion(answer) } }
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

    /// The claim checks its own state's generation: a state change after the
    /// Keychain lookup finished for the right state (or after the auto-fire
    /// started, for an environment value) and before the claim makes it fail.
    func testAStateChangeRightBeforeTheClaimMakesItFail() async {
        let cases: [(TDLibClient.AuthState, CredentialPlan, KeychainCredentialSource)] = [
            (.waitingForPhoneNumber, .fire("+886900000417"), NoKeychainCredentialSource()),
            (.waitingForPassword, .lookUp(.password), FoundSource(value: "stored-secret")),
        ]
        for (state, plan, source) in cases {
            let fake = FakeRequests(answer: .success(()))
            let box = Box()
            let coordinator = AuthCoordinator(credentials: source, requests: fake,
                                              beforeAutomaticClaim: { box.coordinator?.enter(.waitingForCode) })
            box.coordinator = coordinator
            await coordinator.enterCredentialState(state, plan: plan)?.value
            XCTAssertEqual(fake.handOffs, [], "\(state): the value belongs to a state that is gone")
            XCTAssertFalse(coordinator.isSubmittingKeychainCredential, "\(state)")
        }
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

    // MARK: - TDLib's answer and the update handler

    /// TDLibKit runs update handlers and request completions on one serial
    /// queue, and TDLib reports the new state before it answers the request
    /// that caused it. The state change neither blocks the answer nor changes
    /// it: every caller of the coalesced task gets it, and no request is sent
    /// again.
    func testAnUpdateBeforeTheAnswerLeavesTheAnswerToEveryCaller() async {
        let fake = FakeRequests(answer: .success(()), holdFirst: true)
        let box = Box()
        let explicit = Outcome()
        let coordinator = AuthCoordinator(credentials: NoKeychainCredentialSource(), requests: fake,
                                          afterAutomaticClaim: {
            do {
                try await box.coordinator?.sendPhoneNumber("+886911111111")
                explicit.record(nil)
            } catch {
                explicit.record(error)
            }
        })
        box.coordinator = coordinator
        let automatic = coordinator.enterCredentialState(.waitingForPhoneNumber, plan: .fire("+886900000417"))
        await fake.waitForHandOffs(1)
        let updateHandlerQueue = DispatchQueue(label: "update-handler")
        updateHandlerQueue.async { coordinator.enter(.waitingForCode) }
        updateHandlerQueue.async { fake.complete(0, with: .failure(Self.rejected)) }
        await automatic?.value
        XCTAssertEqual(fake.handOffs.map(\.value), ["+886900000417"])
        XCTAssertEqual(coordinator.state, .waitingForCode)
        XCTAssertTrue(Self.isRejected(explicit.errors.first ?? nil), "the explicit caller that joined gets the answer")
        XCTAssertTrue(Self.isRejected(coordinator.lastAutoFireError), "and so does the auto-fire (an environment value's failure is always recorded)")
    }

    /// TDLibKit answers inside the hand-off when `send` throws, that is while
    /// the client lock is held: the answer only reaches `RequestAnswer`, so
    /// nothing waits on the lock.
    func testAnAnswerDeliveredInsideTheHandOffDoesNotBlock() async {
        let fake = FakeRequests(answer: .failure(Self.rejected), inline: true)
        let coordinator = AuthCoordinator(credentials: NoKeychainCredentialSource(), requests: fake)
        let automatic = coordinator.enterCredentialState(.waitingForPassword, plan: .fire("stored-secret"))
        let done = await finished(within: 2) { () -> Bool in
            await automatic?.value
            return true
        }
        XCTAssertEqual(done, true, "the answer was lost: still waiting after 2 s")
        XCTAssertTrue(Self.isRejected(coordinator.lastAutoFireError))
        coordinator.enter(.ready)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(fake.handOffs.map(\.value), ["stored-secret"])
    }

    // MARK: - TDLib's errors as every caller sees them

    /// TDLib's 406 must not be shown and counts as success (`mapTDLibError`),
    /// for the auto-fire and for an explicit caller alike.
    func testATDLib406AnswerCountsAsSuccess() async throws {
        let fake = FakeRequests(answer: .failure(TDLibKit.Error(code: 406, message: "NOT_SHOWN")))
        let coordinator = AuthCoordinator(credentials: FoundSource(value: "stored-secret"), requests: fake)
        await coordinator.enterCredentialState(.waitingForPassword, plan: .lookUp(.password))?.value
        XCTAssertNil(coordinator.lastAutoFireError)
        XCTAssertTrue(coordinator.isSubmittingKeychainCredential,
                      "a submission that succeeded is still on its way until TDLib reports the next state")
        try await coordinator.sendPhoneNumber("+886911111111")
        try await coordinator.sendPassword("typed-secret")
        XCTAssertEqual(fake.handOffs.map(\.method), ["password", "phone", "password"])
    }

    /// Any other TDLib error reaches every caller as `TDError.tdlibError`, and
    /// an automatic value's is recorded for `auth_status`.
    func testATDLibErrorReachesCallersAsTDError() async {
        func isInvalid(_ error: Swift.Error?) -> Bool {
            guard case .tdlibError(400, "PHONE_NUMBER_INVALID")? = error as? TDLibClient.TDError else { return false }
            return true
        }
        let fake = FakeRequests(answer: .failure(TDLibKit.Error(code: 400, message: "PHONE_NUMBER_INVALID")))
        let coordinator = AuthCoordinator(credentials: NoKeychainCredentialSource(), requests: fake)
        await coordinator.enterCredentialState(.waitingForPhoneNumber, plan: .fire("+886900000417"))?.value
        XCTAssertTrue(isInvalid(coordinator.lastAutoFireError), "\(String(describing: coordinator.lastAutoFireError))")
        for explicit in [{ try await coordinator.sendPhoneNumber("+886911111111") },
                         { try await coordinator.sendPassword("typed-secret") }] as [() async throws -> Void] {
            do {
                try await explicit()
                XCTFail("the error was not thrown")
            } catch {
                XCTAssertTrue(isInvalid(error), "\(error)")
            }
        }
    }

    // MARK: - Explicit values before the claim (#96)

    func testAnExplicitValueBeforeTheClaimSendsNoAutomaticOne() async throws {
        let cases: [(TDLibClient.AuthState, KeychainCredential, explicit: String)] = [
            (.waitingForPassword, .password, "typed-secret"),
            (.waitingForPhoneNumber, .phone, "+886911111111"),
        ]
        for (state, credential, explicit) in cases {
            let fake = FakeRequests(answer: .success(()))
            let source = GatedSource()
            let coordinator = AuthCoordinator(credentials: source, requests: fake)
            let automatic = coordinator.enterCredentialState(state, plan: .lookUp(credential))
            await source.waitUntilAsked()
            if credential == .phone {
                try await coordinator.sendPhoneNumber(explicit)
            } else {
                try await coordinator.sendPassword(explicit)
            }
            source.release(.found("stored-value"))
            await automatic?.value
            XCTAssertEqual(fake.handOffs.map(\.value), [explicit], "\(state)")
            XCTAssertFalse(coordinator.isSubmittingKeychainCredential,
                           "\(state): nothing from the Keychain is on its way, so auth_run does not wait for it")
        }
    }

    func testAnExplicitValueForAnotherStepDoesNotCancelThisStepsAutomaticOne() async throws {
        let cases: [(TDLibClient.AuthState, KeychainCredential, stored: String, explicitMethod: String, explicit: String)] = [
            (.waitingForPassword, .password, "stored-secret", "phone", "+886911111111"),
            (.waitingForPhoneNumber, .phone, "+886900000417", "password", "typed-secret"),
        ]
        for (state, credential, stored, explicitMethod, explicit) in cases {
            let fake = FakeRequests(answer: .success(()))
            let source = GatedSource()
            let coordinator = AuthCoordinator(credentials: source, requests: fake)
            let automatic = coordinator.enterCredentialState(state, plan: .lookUp(credential))
            await source.waitUntilAsked()
            if explicitMethod == "phone" {
                try await coordinator.sendPhoneNumber(explicit)
            } else {
                try await coordinator.sendPassword(explicit)
            }
            source.release(.found(stored))
            await automatic?.value
            XCTAssertEqual(fake.handOffs.map(\.value), [explicit, stored], "\(state)")
        }
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
