import Foundation
import os

/// TDLib's two requests that carry a credential the client may send on its
/// own (PsychQuant/che-msg#98). Each hands the request to TDLib and returns at
/// once; `completion` receives TDLib's answer later. They are called under the
/// authorization lock, so they must not block, suspend or take that lock.
internal protocol CredentialRequestSending: Sendable {
    func setAuthenticationPhoneNumber(_ phoneNumber: String,
                                      completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void)
    func checkAuthenticationPassword(_ password: String,
                                     completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void)
}

/// The authorization state TDLib reports, and the phone-number and 2FA-password
/// requests that depend on it, behind one lock. `TDLibClient` feeds it TDLib's
/// updates and forwards the explicit calls; it is kept apart from TDLib so that
/// tests can drive the production path with a fake `CredentialRequestSending`
/// (PsychQuant/che-msg#98).
internal final class AuthCoordinator: @unchecked Sendable {
    /// Non-reentrant lock protecting all mutable auth state.
    /// Critical section MUST NOT contain `await` (OSAllocatedUnfairLock
    /// is non-reentrant; awaiting under the lock can deadlock).
    private let lock = OSAllocatedUnfairLock()

    /// Authentication state. Read via `state`, written under `lock`.
    private var authState: TDLibClient.AuthState = .waitingForParameters

    /// Cached API credentials (from env or tool call). Lock-protected as a pair.
    private var cachedApiId: Int?
    private var cachedApiHash: String?

    /// Most recent error from an auto-fire path, written/cleared by auto-fire
    /// paths and the .ready state transition.
    private var autoFireError: TDLibClient.TDError?

    /// Where the phone number and the 2FA password come from when the
    /// environment has none (PsychQuant/che-msg#49).
    private let credentials: KeychainCredentialSource

    /// The current state's Keychain lookup status. Updated together with
    /// `authState` under `lock`, so a settle check never sees a new state with
    /// the previous state's status.
    let credentialLookups = CredentialLookupTracker()

    /// In-flight task holders for the phone number and the 2FA password.
    /// Concurrent callers of the same method coalesce on these holders.
    private let sendPhoneTask = TaskFieldHolder()
    private let sendPasswordTask = TaskFieldHolder()

    private let requests: CredentialRequestSending

    /// Runs as soon as the step that claims an automatic value has returned,
    /// before the auto-fire waits for TDLib's answer: the first moment another
    /// caller can take `lock`. Tests act there; production passes nothing.
    private let afterAutomaticClaim: @Sendable () async -> Void

    init(credentials: KeychainCredentialSource, requests: CredentialRequestSending,
         afterAutomaticClaim: @escaping @Sendable () async -> Void = {}) {
        self.credentials = credentials
        self.requests = requests
        self.afterAutomaticClaim = afterAutomaticClaim
    }

    // MARK: - State

    var state: TDLibClient.AuthState { lock.withLock { authState } }

    var lastAutoFireError: TDLibClient.TDError? { lock.withLock { autoFireError } }

    /// The inputs of `authorizationIsSettled`, read together.
    func settleInputs() -> (state: TDLibClient.AuthState, keychainLookup: CredentialLookupStatus, hasAutoFireError: Bool) {
        lock.withLock { (authState, credentialLookups.current, autoFireError != nil) }
    }

    /// Enters a state that looks nothing up; `ready` also clears the auto-fire
    /// error.
    func enter(_ state: TDLibClient.AuthState) {
        lock.withLock {
            authState = state
            if state == .ready { autoFireError = nil }
            _ = credentialLookups.stateChanged(lookingUp: false)
        }
    }

    /// Records the API credentials an automatic `setParameters` sends.
    func autoSettingParameters(apiId: Int, apiHash: String) {
        lock.withLock {
            cachedApiId = apiId
            cachedApiHash = apiHash
            autoFireError = nil
        }
    }

    /// Enters the phone-number or 2FA-password state and runs `plan` for it
    /// in a Task (PsychQuant/che-msg#49), so the Keychain is never read on
    /// TDLib's callback thread; the lookup is marked pending together with the
    /// state change, so a settle check waits for it. Returns that Task, or nil
    /// when the plan does nothing.
    @discardableResult
    func enterCredentialState(_ state: TDLibClient.AuthState, plan: CredentialPlan) -> Task<Void, Never>? {
        let lookingUp: Bool
        if case .lookUp = plan { lookingUp = true } else { lookingUp = false }
        let generation: UInt64 = lock.withLock {
            authState = state
            if plan != .nothing { autoFireError = nil }
            return credentialLookups.stateChanged(lookingUp: lookingUp)
        }
        guard plan != .nothing else { return nil }
        let source = credentials
        let tracker = credentialLookups
        return Task { [weak self] in
            await runCredentialPlan(
                plan, generation: generation, tracker: tracker,
                lookup: { await source.lookup($0) },
                submit: { [weak self] value in
                    try await self?.submitAutomatically(value, for: state, generation: generation) ?? false
                },
                recordFailure: { [weak self] error in self?.recordAutoFireError(error) })
        }
    }

    /// Claims the automatic submission for `generation` under the lock that
    /// guards `authState`, so the decision and the state change that would
    /// invalidate it are ordered (#96), then sends the value through the
    /// coalesced path. Returns false, sending nothing, when the claim fails.
    private func submitAutomatically(_ value: String, for state: TDLibClient.AuthState,
                                     generation: UInt64) async throws -> Bool {
        guard state == .waitingForPhoneNumber || state == .waitingForPassword else { return false }
        guard lock.withLock({ credentialLookups.claimSubmission(generation) }) else { return false }
        await afterAutomaticClaim()
        if state == .waitingForPhoneNumber {
            try await requestPhoneNumber(value)
        } else {
            try await requestPassword(value)
        }
        return true
    }

    /// Whether a phone number or 2FA password from the Keychain is being looked
    /// up or submitted for the current state.
    var isSubmittingKeychainCredential: Bool {
        lock.withLock { credentialLookups.isInFlight }
    }

    /// Reads the phone number or the 2FA password from the Keychain source, for
    /// `auth_run`. Returns nil when there is no value, and records why for the
    /// state the lookup started in (#95).
    func lookUpKeychainCredential(_ credential: KeychainCredential) async -> String? {
        // Bound to the state that asks for this credential, read together with
        // it: a lookup that starts after TDLib has moved on records nothing.
        let generation: UInt64? = lock.withLock {
            authState == waitingState(for: credential) ? credentialLookups.generationNow : nil
        }
        let result = await credentials.lookup(credential)
        if let generation { credentialLookups.note(generation, miss: KeychainMiss(result)) }
        return result.value
    }

    /// The authorization state and why its last Keychain lookup produced no
    /// value, read together (#95).
    func stateAndKeychainMiss() -> (state: TDLibClient.AuthState, keychainMiss: KeychainMiss?) {
        lock.withLock { (authState, credentialLookups.lastMiss) }
    }

    /// Persist auto-fire failure for surfacing via `auth_status`.
    /// Only `TDError.tdlibError` is retained; other thrown types are ignored
    /// (they don't represent user-actionable TDLib protocol errors).
    func recordAutoFireError(_ error: Swift.Error) {
        guard let tdError = error as? TDLibClient.TDError else { return }
        if case .tdlibError = tdError {
            lock.withLock { autoFireError = tdError }
        }
    }

    // MARK: - Explicit requests

    /// An explicit phone number: the current state gets no automatic one after
    /// it (#96).
    func sendPhoneNumber(_ phoneNumber: String) async throws {
        // Only while TDLib waits for a phone number: a phone number sent at
        // another step must not cancel that step's automatic value.
        lock.withLock { if authState == .waitingForPhoneNumber { credentialLookups.explicitSubmission() } }
        try await requestPhoneNumber(phoneNumber)
    }

    /// An explicit 2FA password: the current state gets no automatic one after
    /// it (#96).
    func sendPassword(_ password: String) async throws {
        lock.withLock { if authState == .waitingForPassword { credentialLookups.explicitSubmission() } }
        try await requestPassword(password)
    }

    private func requestPhoneNumber(_ phoneNumber: String) async throws {
        try await coalesceTask(holder: sendPhoneTask) { [requests] in
            do {
                try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Void, Swift.Error>) in
                    requests.setAuthenticationPhoneNumber(phoneNumber) { answer.resume(with: $0) }
                }
            } catch {
                try mapTDLibError(error)
            }
        }
    }

    private func requestPassword(_ password: String) async throws {
        try await coalesceTask(holder: sendPasswordTask) { [requests] in
            do {
                try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Void, Swift.Error>) in
                    requests.checkAuthenticationPassword(password) { answer.resume(with: $0) }
                }
            } catch {
                try mapTDLibError(error)
            }
        }
    }
}
