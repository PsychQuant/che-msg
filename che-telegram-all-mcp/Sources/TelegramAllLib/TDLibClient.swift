import Foundation
import TDLibKit
import TDLibFramework

// MARK: - File-scope helpers (testable seams)

/// Configures the `JSONDecoder` used to decode TDLib `Update` broadcast payloads.
///
/// CRITICAL invariant — `keyDecodingStrategy` MUST be `.convertFromSnakeCase`. TDLib
/// emits snake_case keys (`authorization_state`, `chat_id`, etc.), Swift Codable
/// types use camelCase. Without this strategy every `Update` decode silently fails
/// inside `TDLibClient`'s callback `do/catch`, freezing `authState` at
/// `.waitingForParameters`. This was the v0.2.0 critical bug.
///
/// Exposed at file scope so `JSONDecoderRegressionTests` can verify the contract
/// without instantiating `TDLibClient` (TDLib's receive loop is process-global).
internal func makeUpdateDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

/// Maps a `Swift.Error` thrown by a TDLib auth call into either a structured
/// `TDLibClient.TDError.tdlibError(code:message:)` or a silent return (code 406).
///
/// Per the TDLib protocol contract documented in
/// `Sources/TDLibKit/Generated/Models/Error.swift`:
/// > "If the error code is 406, the error message must not be processed in any
/// >  way and must not be displayed to the user."
///
/// Exposed at file scope so `TDLibAuthErrorTests` can verify the mapping
/// without instantiating `TDLibClient`.
///
/// - Parameter error: The error caught from a TDLibKit auth call.
/// - Throws: `TDLibClient.TDError.tdlibError(code:message:)` for any TDLibKit
///   error other than code 406; rethrows non-TDLibKit errors unchanged.
internal func mapTDLibError(_ error: Swift.Error) throws {
    guard let td = error as? TDLibKit.Error else {
        throw error
    }
    guard td.code != 406 else {
        // Silent-ignore per TDLib protocol. Caller treats this as success.
        return
    }
    throw TDLibClient.TDError.tdlibError(code: td.code, message: td.message)
}

/// `CredentialRequestSending` through TDLibKit's callback forms, which put the
/// request on TDLibKit's send queue and return without waiting
/// (PsychQuant/che-msg#98).
struct TDLibKitCredentialRequests: CredentialRequestSending, @unchecked Sendable {
    let client: TDLibKit.TDLibClient

    func setAuthenticationPhoneNumber(_ phoneNumber: String,
                                      completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void) {
        do {
            try client.setAuthenticationPhoneNumber(phoneNumber: phoneNumber, settings: nil) { completion($0.map { _ in }) }
        } catch {
            completion(.failure(error))
        }
    }

    func checkAuthenticationPassword(_ password: String,
                                     completion: @escaping @Sendable (Result<Void, Swift.Error>) -> Void) {
        do {
            try client.checkAuthenticationPassword(password: password) { completion($0.map { _ in }) }
        } catch {
            completion(.failure(error))
        }
    }
}

/// Manages a TDLib client session with authentication state tracking.
public final class TDLibClient {
    /// One manager, and so one `td_receive` loop, for the whole process. TDLib
    /// allows only one thread at a time in `td_receive`, and every manager runs
    /// its own loop that can stay blocked in it for 10 seconds, so a client
    /// reopened after an idle close must not bring a second manager
    /// (PsychQuant/che-msg#58).
    private static let manager = TDLibClientManager()
    /// Private so that every request goes through `openClient`, which checks
    /// first that TDLib has not closed this client (#64); used directly only
    /// to close it.
    private let client: TDLibKit.TDLibClient
    private let dbPath: String

    /// The authorization state, the auto-fire error, the Keychain lookup
    /// status and the phone-number and 2FA-password requests, behind one lock
    /// (PsychQuant/che-msg#98).
    private let auth: AuthCoordinator

    /// In-flight task holders for `setParameters` and `sendAuthCode`. Concurrent
    /// callers of the same method coalesce on these holders — see `coalesceTask`.
    /// The phone number's and the 2FA password's are in `auth`.
    private let setParametersTask = TaskFieldHolder()
    private let sendCodeTask = TaskFieldHolder()

    /// Weak reference holder to break the init capture cycle.
    private class Weak {
        weak var value: TDLibClient?
    }

    public enum AuthState: String, Sendable {
        case waitingForParameters
        case waitingForPhoneNumber
        case waitingForCode
        case waitingForPassword
        case ready
        /// TDLib is logging out or closing (`authorizationStateLoggingOut`,
        /// `authorizationStateClosing`; #64). Without it `auth_status` kept
        /// reporting `ready` until TDLib had closed.
        case closing
        /// TDLib has finished closing (`authorizationStateClosed`): what
        /// `close(timeout:)` and the lifecycle wait for before releasing the lock.
        case closed
    }

    public enum TDError: LocalizedError {
        case notAuthenticated
        case missingCredentials(String)
        case tdlibError(code: Int, message: String)
        /// TDLib is closing or has closed this client, so the request was not
        /// sent (#64). The server goes on handing out a client TDLib has
        /// closed until a logout succeeds, the idle close runs or the server
        /// restarts, and the message says so. It must stay within
        /// `errorResultFromParse`'s 256-character cap.
        case sessionClosed
        /// TDLib has not loaded the chat and has no information about its user or group, so it
        /// could not be created from its id; `code` and `message` are those of TDLib's
        /// `getChat` error (#71, see `loadChat`).
        case unknownChat(chatId: Int64, code: Int, message: String)

        /// What the caller can do next, for the errors that have a next step: only `unknownChat`.
        /// `get_chats` sends `getChats` with no chat list, which TDLib reads as the main list.
        public var hint: String? {
            guard case .unknownChat(let chatId, _, _) = self else { return nil }
            return "TDLib has no information about chat \(chatId), so it could not load the chat by its id. "
                + "Call get_chats (CLI: telegram-all chats) with a limit large enough to reach this chat, "
                + "so that TDLib loads it, then try again. get_chats reads only the main chat list, "
                + "so it does not load a chat archived in Telegram."
        }

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not authenticated. Use auth_set_parameters, auth_send_phone, and auth_send_code first."
            case .missingCredentials(let msg): return "Missing: \(msg)"
            case .tdlibError(let code, let message): return "TDLib error \(code): \(message)"
            case .unknownChat(_, let code, let message): return "TDLib error \(code): \(message). " + (hint ?? "")
            case .sessionClosed:
                // The idle close happens only when the timeout is not 0 and no call is
                // running (TDLibLifecycle.checkIdle); the whole text stays under the
                // 256-character cap of error results.
                return "TDLib is closing or has closed this session; no request was sent. "
                    + "A new session opens on the first call after a successful logout, after the idle close "
                    + "(when \(IdleTimeout.environmentVariable) is not 0, once no call is running), or after a reconnect with /mcp."
            }
        }
    }

    /// Where connection states are recorded (#63). Owned by the server, so
    /// the unsynced time survives this client being closed and replaced.
    private let syncState: TDLibSyncState?

    /// `credentials` is where the phone number and the 2FA password are read
    /// when the environment does not set them; tests inject a fake.
    public init(logVerbosity: Int = 0, syncState: TDLibSyncState? = nil,
                credentials: KeychainCredentialSource = SecurityCLICredentialSource()) async throws {
        self.syncState = syncState
        // Silence TDLib's stdout spam BEFORE creating any client.
        // td_execute is synchronous, thread-safe, and doesn't need a client.
        let logRequest = #"{"@type":"setLogVerbosityLevel","new_verbosity_level":\#(logVerbosity)}"#
        _ = td_execute(logRequest)

        dbPath = Self.databaseDirectory
        try FileManager.default.createDirectory(atPath: dbPath, withIntermediateDirectories: true)
        // Before the client exists, so no connection state it reports is lost.
        syncState?.tdlibOpened()

        let decoder = makeUpdateDecoder()
        let weakRef = Weak()
        client = Self.manager.createClient { data, _ in
            guard let strongSelf = weakRef.value else { return }
            do {
                let update = try decoder.decode(Update.self, from: data)
                strongSelf.handleUpdate(update)
            } catch {
                // Ignore decode errors for unknown updates
            }
        }
        auth = AuthCoordinator(credentials: credentials, requests: TDLibKitCredentialRequests(client: client))
        weakRef.value = self
    }

    /// The TDLib database directory (`td.binlog`, `db.sqlite`).
    public static var databaseDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("che-telegram-all-mcp/tdlib").path
    }

    deinit {
        // Close this client and wait until TDLib has, as
        // `TDLibClientManager.closeClients` did when each client had its own
        // manager. A client already closed has left the manager.
        guard Self.manager.clients.contains(client.id) else { return }
        try? client.close(completion: { _ in })
        let deadline = Date().addingTimeInterval(30)
        while Self.manager.clients.contains(client.id), Date() < deadline {
            usleep(10_000)
        }
    }

    /// Waits until authorization has gone as far as it can without a caller
    /// (`authorizationIsSettled`), or until `timeout` seconds pass. A client
    /// opened on demand otherwise answers its first call with "Not
    /// authenticated" while TDLib is still logging in (PsychQuant/che-msg#58).
    public func waitForAuthorizationToSettle(timeout: TimeInterval) async {
        let env = ProcessInfo.processInfo.environment
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            let (state, keychainLookup, hasError) = auth.settleInputs()
            let settled = authorizationIsSettled(
                state: state, hasAutoFireError: hasError,
                envApiId: env["TELEGRAM_API_ID"].flatMap(Int.init), envApiHash: env["TELEGRAM_API_HASH"],
                envPhone: env["TELEGRAM_PHONE"], envPassword: env["TELEGRAM_2FA_PASSWORD"],
                keychainLookup: keychainLookup)
            if settled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Only an authorized TDLib can sync with Telegram, so only then is it
    /// worth waiting for (#63).
    static func shouldWaitForSync(authState: AuthState) -> Bool { authState == .ready }

    /// Waits until `isReady` returns true or `timeout` seconds pass; returns
    /// whether it became ready. Clock and sleep are injected for tests.
    static func wait(timeout: TimeInterval, now: () -> TimeInterval,
                     sleep: (TimeInterval) async -> Void, until isReady: () -> Bool) async -> Bool {
        let deadline = now() + timeout
        while !isReady() {
            // A cancelled call stops at once: a cancelled Task.sleep returns
            // immediately, which would otherwise spin to the deadline.
            if Task.isCancelled || now() >= deadline { return false }
            await sleep(0.05)
        }
        return true
    }

    /// After TDLib opens, waits up to `timeout` seconds for it to sync with
    /// Telegram, so the call that opened it does not answer from data TDLib
    /// has not brought up to date yet (#63). Does not wait while
    /// authorization is not ready.
    public func waitForConnectionReady(timeout: TimeInterval, isReady: () -> Bool) async -> Bool {
        guard Self.shouldWaitForSync(authState: getAuthState()) else { return false }
        return await Self.wait(timeout: timeout, now: { Date().timeIntervalSince1970 },
                               sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                               until: isReady)
    }

    /// Asks TDLib to close and waits for `authorizationStateClosed`. Returns
    /// false if TDLib has not reported it within `timeout` seconds.
    public func close(timeout: TimeInterval) async -> Bool {
        await Self.close(timeout: timeout, now: { Date().timeIntervalSince1970 },
                         sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                         isClosed: { getAuthState() == .closed },
                         send: { [weak self] in _ = try? await self?.client.close() })
    }

    /// Sends the close request without awaiting its answer and waits until
    /// `isClosed` or `timeout` seconds pass (#64). TDLibKit routes no answer
    /// to a client it has already dropped, so awaiting the request could
    /// never return; TDLib reports the close as a state update either way. A
    /// cancelled call stops at once, like `wait`, and returns false.
    static func close(timeout: TimeInterval, now: () -> TimeInterval, sleep: (TimeInterval) async -> Void,
                      isClosed: () -> Bool, send: @escaping @Sendable () async -> Void) async -> Bool {
        if isClosed() { return true }
        Task { await send() }
        return await wait(timeout: timeout, now: now, sleep: sleep, until: isClosed)
    }

    // MARK: - Update Handler

    private func handleUpdate(_ update: Update) {
        if let syncState { Self.applySyncUpdate(update, to: syncState) }
        switch update {
        case .updateAuthorizationState(let state):
            handleAuthStateUpdate(state.authorizationState)
        default:
            break
        }
    }

    /// Feeds the updates that tell whether TDLib is synced with Telegram into
    /// `state` (#63): connection states, and the authorization state closing.
    /// Reads no error messages.
    static func applySyncUpdate(_ update: Update, to state: TDLibSyncState) {
        switch update {
        case .updateConnectionState(let change):
            state.record(connectionStateName(change.state))
        case .updateAuthorizationState(let change):
            if case .authorizationStateClosed = change.authorizationState { state.tdlibClosed() }
        default:
            break
        }
    }

    /// The TDLib API name of a connection state, as `auth_status` reports it.
    static func connectionStateName(_ state: ConnectionState) -> String {
        switch state {
        case .connectionStateWaitingForNetwork: return "connectionStateWaitingForNetwork"
        case .connectionStateConnectingToProxy: return "connectionStateConnectingToProxy"
        case .connectionStateConnecting: return "connectionStateConnecting"
        case .connectionStateUpdating: return "connectionStateUpdating"
        case .connectionStateReady: return TDLibSyncState.readyState
        }
    }

    /// The state this client tracks for TDLib's authorization state; nil for
    /// the states it has no value for, which leave the current one as it is.
    /// Logging out and closing are one state, `closing`, so that `closed`
    /// keeps meaning TDLib has finished closing (#64).
    static func authState(for state: AuthorizationState) -> AuthState? {
        switch state {
        case .authorizationStateWaitTdlibParameters: return .waitingForParameters
        case .authorizationStateWaitPhoneNumber: return .waitingForPhoneNumber
        case .authorizationStateWaitCode: return .waitingForCode
        case .authorizationStateWaitPassword: return .waitingForPassword
        case .authorizationStateReady: return .ready
        case .authorizationStateLoggingOut, .authorizationStateClosing: return .closing
        case .authorizationStateClosed: return .closed
        default: return nil
        }
    }

    private func handleAuthStateUpdate(_ state: AuthorizationState) {
        guard let tracked = Self.authState(for: state) else { return }
        switch tracked {
        case .waitingForParameters:
            enterStateWithoutLookup(.waitingForParameters)
            autoSetParametersIfAvailable()
        case .waitingForPhoneNumber:
            enterCredentialState(.waitingForPhoneNumber)
        case .waitingForCode:
            // Spec requirement: SMS verification code is never auto-fired from
            // environment or the Keychain. The code MUST be supplied by an
            // explicit caller invocation (auth_run(code:) or auth_send_code(code:)).
            // DO NOT add an auto-fire or a lookup here.
            enterStateWithoutLookup(.waitingForCode)
        case .waitingForPassword:
            enterCredentialState(.waitingForPassword)
        case .ready:
            enterStateWithoutLookup(.ready)
        case .closing, .closed:
            enterStateWithoutLookup(tracked)
        }
    }

    private func enterStateWithoutLookup(_ state: AuthState) {
        auth.enter(state)
    }

    /// Auto-set TDLib parameters from environment variables if available.
    private func autoSetParametersIfAvailable() {
        let env = ProcessInfo.processInfo.environment
        let apiIdEnv = env["TELEGRAM_API_ID"].flatMap(Int.init)
        let action = decideAutoFire(
            state: getAuthState(),
            envApiId: apiIdEnv,
            envApiHash: env["TELEGRAM_API_HASH"],
            envPhone: env["TELEGRAM_PHONE"],
            envPassword: env["TELEGRAM_2FA_PASSWORD"],
            // Spec: "SMS verification code is never auto-fired from environment" —
            // the client does not read TELEGRAM_AUTH_CODE at all (#87).
            envAuthCode: nil
        )
        guard case .fireSetParameters(let apiId, let apiHash) = action else { return }
        auth.autoSettingParameters(apiId: apiId, apiHash: apiHash)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.setParameters(apiId: apiId, apiHash: apiHash)
            } catch {
                self.recordAutoFireError(error)
            }
        }
    }

    /// Enters the phone-number or 2FA-password state and auto-fires its
    /// credential: the environment's value if set, otherwise the Keychain's
    /// (PsychQuant/che-msg#49). Runs on TDLib's callback thread, so the
    /// Keychain is read inside the coordinator's Task, never here.
    private func enterCredentialState(_ state: AuthState) {
        let env = ProcessInfo.processInfo.environment
        let plan = credentialPlan(state: state, envPhone: env["TELEGRAM_PHONE"],
                                  envPassword: env["TELEGRAM_2FA_PASSWORD"])
        auth.enterCredentialState(state, plan: plan)
    }

    /// Whether a phone number or 2FA password from the Keychain is being looked
    /// up or submitted for the current state (`auth_run` waits for it rather
    /// than asking the caller for the value).
    public var isSubmittingKeychainCredential: Bool {
        auth.isSubmittingKeychainCredential
    }

    /// Reads the phone number or the 2FA password from the Keychain source, for
    /// `auth_run` when neither the caller nor the environment supplies it.
    /// Returns nil when there is no value, and records why for the state the
    /// lookup started in (#95).
    public func lookUpKeychainCredential(_ credential: KeychainCredential) async -> String? {
        await auth.lookUpKeychainCredential(credential)
    }

    /// The authorization state and why its last Keychain lookup produced no
    /// value (nil when none did or none ran), read together so that the
    /// outcome belongs to that state (#95). The generation a lookup records
    /// against changes only under the same lock.
    public func authStateAndKeychainMiss() -> (state: AuthState, keychainMiss: KeychainMiss?) {
        auth.stateAndKeychainMiss()
    }

    /// Persist auto-fire failure for surfacing via `auth_status`.
    private func recordAutoFireError(_ error: Swift.Error) {
        auth.recordAutoFireError(error)
    }

    // MARK: - Requests

    /// Why a request may not be sent in `state`, or nil when it may (#64).
    /// TDLibKit drops a client from its table on `authorizationStateClosed`
    /// and routes no answer to it, so a request sent after that never returns
    /// and its call never ends; while TDLib logs out or closes nothing sent can
    /// do any good either. With `authorized`, the request also needs
    /// authorization to be ready.
    static func requestRefusal(state: AuthState, authorized: Bool) -> TDError? {
        switch state {
        case .closing, .closed: return .sessionClosed
        case .ready: return nil
        case .waitingForParameters, .waitingForPhoneNumber, .waitingForCode, .waitingForPassword:
            return authorized ? .notAuthenticated : nil
        }
    }

    /// Throws `requestRefusal` for the state read under the coordinator's
    /// lock. The phone number and the 2FA password are checked by
    /// `AuthCoordinator` instead, under the lock their request is handed to
    /// TDLib under. A request already sent when TDLib closes is not covered;
    /// that stays with the lifecycle findings (1 to 3) of #64.
    func requireOpen(authorized: Bool = false) throws {
        if let refusal = Self.requestRefusal(state: auth.state, authorized: authorized) {
            throw refusal
        }
    }

    /// The TDLibKit client for one request, after `requireOpen` (#64): every
    /// request, including each page of a paging loop, goes through this. The
    /// check and the request are not one step: TDLib can still close between
    /// them, and that request then waits forever as before. Closing that window
    /// needs the lifecycle to stop new calls before it closes (#64 findings 1–3).
    var openClient: TDLibKit.TDLibClient {
        get throws {
            try requireOpen()
            return client
        }
    }

    /// The chat `chatId`, made known to TDLib first (#71): see `loadChat`, which decides which
    /// request to send and with what; these closures pass the arguments through unchanged
    /// (`TDLibRequestTests` pins them). Every method that takes a chat id calls this before
    /// its first request on the chat.
    @discardableResult
    func knownChat(_ chatId: Int64) async throws -> Chat {
        try await loadChat(
            chatId,
            get: { try await tdlibCall { try await openClient.getChat(chatId: chatId) } },
            createPrivateChat: { force, userId in try await tdlibCall { try await openClient.createPrivateChat(force: force, userId: userId) } },
            createBasicGroupChat: { basicGroupId, force in try await tdlibCall { try await openClient.createBasicGroupChat(basicGroupId: basicGroupId, force: force) } },
            createSupergroupChat: { force, supergroupId in try await tdlibCall { try await openClient.createSupergroupChat(force: force, supergroupId: supergroupId) } })
    }

    // MARK: - Authentication

    public func setParameters(apiId: Int, apiHash: String) async throws {
        try await coalesceTask(holder: setParametersTask) { [self] in
            do {
                _ = try await openClient.setTdlibParameters(
                    apiHash: apiHash,
                    apiId: apiId,
                    applicationVersion: "0.1.0",
                    databaseDirectory: dbPath,
                    databaseEncryptionKey: Data(),
                    deviceModel: "macOS",
                    filesDirectory: dbPath + "/files",
                    systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: false,
                    useTestDc: false
                )
            } catch {
                try mapTDLibError(error)
            }
        }
    }

    /// An explicit phone number (`auth_run`, `auth_send_phone`, the CLI): the
    /// current state gets no automatic one after it (#96).
    public func sendPhoneNumber(_ phoneNumber: String) async throws {
        try await auth.sendPhoneNumber(phoneNumber)
    }

    public func sendAuthCode(_ code: String) async throws {
        try await coalesceTask(holder: sendCodeTask) { [self] in
            do {
                _ = try await openClient.checkAuthenticationCode(code: code)
            } catch {
                try mapTDLibError(error)
            }
        }
    }

    /// An explicit 2FA password: the current state gets no automatic one after
    /// it (#96).
    public func sendPassword(_ password: String) async throws {
        try await auth.sendPassword(password)
    }

    /// Returns the current authentication state. Lock-protected — never
    /// observes a torn enum value.
    public func getAuthState() -> AuthState {
        auth.state
    }

    /// Legacy accessor returning the raw-value string. Prefer the
    /// `AuthState`-returning overload for type-safe comparisons.
    public func getAuthState() -> String {
        let state: AuthState = self.getAuthState()
        return state.rawValue
    }

    /// Returns the most recent error from an auto-fire path, or nil if none.
    /// Cleared automatically when a new auto-fire begins or `authState`
    /// advances to `.ready`.
    public func getLastAutoFireError() -> TDError? {
        auth.lastAutoFireError
    }

    // MARK: - Chat Operations

    public func getChats(limit: Int = 50) async throws -> String {
        try requireOpen(authorized: true)
        let result = try await tdlibCall { try await openClient.getChats(chatList: nil, limit: limit) }
        var chats: [[String: Any]] = []
        for chatId in result.chatIds {
            let chat = try await tdlibCall { try await openClient.getChat(chatId: chatId) }
            chats.append(chatToDict(chat))
        }
        return toJSON(chats)
    }

    public func getChat(chatId: Int64) async throws -> String {
        try requireOpen(authorized: true)
        let chat = try await knownChat(chatId)
        return toJSON(chatToDict(chat))
    }

    public func getChatHistory(
        chatId: Int64,
        limit: Int = 50,
        fromMessageId: Int64 = 0,
        maxMessages: Int? = nil,
        sinceDate: Foundation.Date? = nil,
        untilDate: Foundation.Date? = nil
    ) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)

        // Backward-compatible single-page path: when no bulk/filter params are given,
        // behave exactly as the prior implementation (one TDLib call, raw batch, no filtering).
        if maxMessages == nil && sinceDate == nil && untilDate == nil {
            let result = try await tdlibCall { try await openClient.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: 0,
                onlyLocal: false
            ) }
            let messages = result.messages?.map { messageToDict($0) } ?? []
            return toJSON(messages)
        }

        // Single-page + date-filter path: one TDLib call, client-side date filter applied.
        if maxMessages == nil {
            let result = try await tdlibCall { try await openClient.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: 0,
                onlyLocal: false
            ) }
            let rawBatch = result.messages?.map { messageToDict($0) } ?? []
            let filtered = filterMessagesByDate(rawBatch, since: sinceDate, until: untilDate)
            return toJSON(filtered)
        }

        // Bulk pagination path: iterate TDLib calls until termination condition met.
        // Hard cap: 10_000 messages. Prevents runaway pagination from accidentally or
        // maliciously large `max_messages` values (each page = one TDLib roundtrip).
        // Rationale: 10k covers near-all realistic use cases; larger exports should use
        // `dump_chat_to_markdown` with explicit date bounds instead of unbounded pagination.
        let requested = maxMessages!
        let cap = min(requested, 10_000)
        if requested > 10_000 {
            fputs(
                "warning: TDLibClient.getChatHistory capped maxMessages \(requested) -> \(cap) (#6)\n",
                stderr
            )
        }
        let pageSize = min(max(limit, 1), 100)
        var accumulated: [[String: Any]] = []
        var nextFromId: Int64 = fromMessageId

        while accumulated.count < cap {
            let result = try await tdlibCall { try await openClient.getChatHistory(
                chatId: chatId,
                fromMessageId: nextFromId,
                limit: pageSize,
                offset: 0,
                onlyLocal: false
            ) }
            let batch = result.messages?.map { messageToDict($0) } ?? []

            let step = accumulatePaginationBatch(
                current: accumulated,
                newBatch: batch,
                sinceDate: sinceDate,
                untilDate: untilDate,
                maxMessages: cap
            )
            accumulated = step.accumulated
            if !step.shouldContinue { break }
            guard let next = step.nextFromMessageId else { break }
            nextFromId = next
        }

        return toJSON(accumulated)
    }

    public func searchChats(query: String, limit: Int = 20) async throws -> String {
        try requireOpen(authorized: true)
        let result = try await tdlibCall { try await openClient.searchChats(limit: limit, query: query) }
        var chats: [[String: Any]] = []
        for chatId in result.chatIds {
            let chat = try await tdlibCall { try await openClient.getChat(chatId: chatId) }
            chats.append(chatToDict(chat))
        }
        return toJSON(chats)
    }

    // MARK: - Message Operations

    public func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64? = nil) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        var replyTo: InputMessageReplyTo? = nil
        if let replyId = replyToMessageId {
            replyTo = .inputMessageReplyToMessage(
                InputMessageReplyToMessage(checklistTaskId: 0, messageId: replyId, quote: nil)
            )
        }
        let result = try await tdlibCall { try await openClient.sendMessage(
            chatId: chatId,
            inputMessageContent: content,
            options: nil,
            replyMarkup: nil,
            replyTo: replyTo,
            topicId: nil
        ) }
        return toJSON(messageToDict(result))
    }

    public func editMessage(chatId: Int64, messageId: Int64, text: String) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        let result = try await tdlibCall { try await openClient.editMessageText(
            chatId: chatId,
            inputMessageContent: content,
            messageId: messageId,
            replyMarkup: nil
        ) }
        return toJSON(messageToDict(result))
    }

    public func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool = true) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.deleteMessages(chatId: chatId, messageIds: messageIds, revoke: revoke) }
        return "{\"ok\": true}"
    }

    public func forwardMessages(chatId: Int64, fromChatId: Int64, messageIds: [Int64]) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(fromChatId)
        try await knownChat(chatId)
        let result = try await tdlibCall { try await openClient.forwardMessages(
            chatId: chatId,
            fromChatId: fromChatId,
            messageIds: messageIds,
            options: nil,
            removeCaption: false,
            sendCopy: false,
            topicId: nil
        ) }
        let messages = result.messages?.map { messageToDict($0) } ?? []
        return toJSON(messages)
    }

    public func searchMessages(chatId: Int64, query: String, limit: Int = 50) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        let result = try await tdlibCall { try await openClient.searchChatMessages(
            chatId: chatId,
            filter: nil,
            fromMessageId: 0,
            limit: limit,
            offset: 0,
            query: query,
            senderId: nil,
            topicId: nil
        ) }
        let messages = result.messages.map { messageToDict($0) }
        return toJSON(messages)
    }

    // MARK: - Contact / User Operations

    public func getMe() async throws -> String {
        try requireOpen(authorized: true)
        let me = try await tdlibCall { try await openClient.getMe() }
        return toJSON(userToDict(me))
    }

    public func getUser(userId: Int64) async throws -> String {
        try requireOpen(authorized: true)
        let user = try await tdlibCall { try await openClient.getUser(userId: userId) }
        return toJSON(userToDict(user))
    }

    public func getContacts(limit: Int = 200) async throws -> String {
        try requireOpen(authorized: true)
        let result = try await tdlibCall { try await openClient.getContacts() }
        var users: [[String: Any]] = []
        // #34: TDLib's getContacts has no server-side limit (unlike getChats /
        // searchChats), so it returns ALL contact ids. Bound the expensive
        // one-getUser-per-id fan-out client-side via `boundedContactIds`.
        for userId in boundedContactIds(result.userIds, limit: limit) {
            let user = try await tdlibCall { try await openClient.getUser(userId: userId) }
            users.append(userToDict(user))
        }
        return toJSON(users)
    }

    // MARK: - Group Management

    public func getChatMembers(chatId: Int64, limit: Int = 200) async throws -> String {
        try requireOpen(authorized: true)
        let chat = try await knownChat(chatId)
        switch chat.type {
        case .chatTypeSupergroup(let sg):
            let result = try await tdlibCall { try await openClient.getSupergroupMembers(
                filter: nil,
                limit: limit,
                offset: 0,
                supergroupId: sg.supergroupId
            ) }
            let members = result.members.map { memberToDict($0) }
            return toJSON(members)
        case .chatTypeBasicGroup(let bg):
            let info = try await tdlibCall { try await openClient.getBasicGroupFullInfo(basicGroupId: bg.basicGroupId) }
            let members = info.members.map { memberToDict($0) }
            return toJSON(members)
        default:
            return "[]"
        }
    }

    public func pinMessage(chatId: Int64, messageId: Int64, disableNotification: Bool = false) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.pinChatMessage(
            chatId: chatId,
            disableNotification: disableNotification,
            messageId: messageId,
            onlyForSelf: false
        ) }
        return "{\"ok\": true}"
    }

    public func unpinMessage(chatId: Int64, messageId: Int64) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.unpinChatMessage(chatId: chatId, messageId: messageId) }
        return "{\"ok\": true}"
    }

    public func setChatTitle(chatId: Int64, title: String) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.setChatTitle(chatId: chatId, title: title) }
        return "{\"ok\": true}"
    }

    public func setChatDescription(chatId: Int64, description: String) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.setChatDescription(chatId: chatId, description: description) }
        return "{\"ok\": true}"
    }

    // MARK: - Group Creation

    public func createGroup(title: String, userIds: [Int64]) async throws -> String {
        try requireOpen(authorized: true)
        let created = try await tdlibCall { try await openClient.createNewBasicGroupChat(
            messageAutoDeleteTime: 0,
            title: title,
            userIds: userIds
        ) }
        let chat = try await tdlibCall { try await openClient.getChat(chatId: created.chatId) }
        return toJSON(chatToDict(chat))
    }

    public func addChatMember(chatId: Int64, userId: Int64) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.addChatMember(chatId: chatId, forwardLimit: 0, userId: userId) }
        return "{\"ok\": true}"
    }

    // MARK: - Read State

    public func markAsRead(chatId: Int64, messageIds: [Int64]) async throws -> String {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        _ = try await tdlibCall { try await openClient.viewMessages(
            chatId: chatId,
            forceRead: true,
            messageIds: messageIds,
            source: nil
        ) }
        return "{\"ok\": true}"
    }

    // MARK: - Logout

    // MARK: - Serialization Helpers

    private func chatToDict(_ chat: Chat) -> [String: Any] {
        var dict: [String: Any] = [
            "id": chat.id,
            "title": chat.title,
            "unread_count": chat.unreadCount,
        ]
        switch chat.type {
        case .chatTypePrivate: dict["type"] = "private"
        case .chatTypeBasicGroup: dict["type"] = "basic_group"
        case .chatTypeSupergroup(let sg):
            dict["type"] = sg.isChannel ? "channel" : "supergroup"
        case .chatTypeSecret: dict["type"] = "secret"
        }
        if let lastMsg = chat.lastMessage {
            dict["last_message"] = messageToDict(lastMsg)
        }
        return dict
    }

    func messageToDict(_ msg: Message) -> [String: Any] {
        var dict: [String: Any] = [
            "id": msg.id,
            "chat_id": msg.chatId,
            "date": msg.date,
            "sender": senderToDict(msg.senderId),
            "is_outgoing": msg.isOutgoing,
        ]
        dict.merge(messageContentFields(msg.content)) { _, fromContent in fromContent }
        if let file = mediaFileInfo(msg.content) { dict["file"] = file }
        return dict
    }

    private func senderToDict(_ sender: MessageSender) -> [String: Any] {
        switch sender {
        case .messageSenderUser(let user):
            return ["type": "user", "user_id": user.userId]
        case .messageSenderChat(let chat):
            return ["type": "chat", "chat_id": chat.chatId]
        }
    }

    private func userToDict(_ user: User) -> [String: Any] {
        [
            "id": user.id,
            "first_name": user.firstName,
            "last_name": user.lastName,
            "username": user.usernames?.activeUsernames.first ?? "",
            "phone_number": user.phoneNumber,
            "is_contact": user.isContact,
        ]
    }

    private func memberToDict(_ member: ChatMember) -> [String: Any] {
        var dict: [String: Any] = [
            "member_id": senderToDict(member.memberId),
            "joined_date": member.joinedChatDate,
        ]
        switch member.status {
        case .chatMemberStatusCreator: dict["status"] = "creator"
        case .chatMemberStatusAdministrator: dict["status"] = "administrator"
        case .chatMemberStatusMember: dict["status"] = "member"
        case .chatMemberStatusRestricted: dict["status"] = "restricted"
        case .chatMemberStatusBanned: dict["status"] = "banned"
        case .chatMemberStatusLeft: dict["status"] = "left"
        }
        return dict
    }

    private func toJSON(_ value: Any) -> String {
        JSONOutput.string(value)
    }
}

extension TDLibClient: TDLibClosable {}

/// The `type` of a message's content and the fields that come with it: text, caption, file name,
/// a sticker's emoji, a location's coordinates, a poll's question and options (#82). Content it does
/// not map has `type` "other" plus `unmappedContentFields`: its TDLib `content_type` and, for seven
/// kinds, what the content says (#117).
internal func messageContentFields(_ content: MessageContent) -> [String: Any] {
    var fields: [String: Any] = [:]
    switch content {
    case .messageText(let text):
        fields["type"] = "text"
        fields["text"] = text.text.text
    case .messagePhoto(let photo):
        fields["type"] = "photo"
        fields["caption"] = photo.caption.text
    case .messageVideo(let video):
        fields["type"] = "video"
        fields["caption"] = video.caption.text
    case .messageDocument(let doc):
        fields["type"] = "document"
        fields["file_name"] = doc.document.fileName
        fields["caption"] = doc.caption.text
    case .messageSticker(let sticker):
        fields["type"] = "sticker"
        fields["emoji"] = sticker.sticker.emoji
    case .messageVoiceNote(let voice):
        fields["type"] = "voice_note"
        fields["caption"] = voice.caption.text
    case .messageVideoNote:
        fields["type"] = "video_note"
    case .messageAnimation(let animation):
        fields["type"] = "animation"
        fields["caption"] = animation.caption.text
    case .messageAudio(let audio):
        fields["type"] = "audio"
        fields["caption"] = audio.caption.text
    case .messageLocation(let loc):
        fields["type"] = "location"
        fields["latitude"] = loc.location.latitude
        fields["longitude"] = loc.location.longitude
    case .messagePoll(let poll):
        fields["type"] = "poll"
        fields["question"] = poll.poll.question.text
        fields["options"] = poll.poll.options.map { $0.text.text }
    default:
        fields["type"] = "other"
        fields.merge(unmappedContentFields(content)) { current, _ in current }   // #117
    }
    return fields
}

/// The downloadable file of a message's content as `{"id","size","name"?}`, or nil when the
/// content carries no file (PsychQuant/che-msg#69). Photos use their largest size.
internal func mediaFileInfo(_ content: MessageContent) -> [String: Any]? {
    func info(_ file: File, name: String?) -> [String: Any] {
        var dict: [String: Any] = ["id": file.id, "size": file.size > 0 ? file.size : file.expectedSize]
        if let name, !name.isEmpty { dict["name"] = name }
        return dict
    }
    switch content {
    case .messagePhoto(let m):
        guard let largest = m.photo.sizes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return info(largest.photo, name: nil)
    case .messageVideo(let m): return info(m.video.video, name: m.video.fileName)
    case .messageDocument(let m): return info(m.document.document, name: m.document.fileName)
    case .messageAudio(let m): return info(m.audio.audio, name: m.audio.fileName)
    case .messageVoiceNote(let m): return info(m.voiceNote.voice, name: nil)
    case .messageVideoNote(let m): return info(m.videoNote.video, name: nil)
    case .messageAnimation(let m): return info(m.animation.animation, name: m.animation.fileName)
    case .messageSticker(let m): return info(m.sticker.sticker, name: nil)
    default: return nil
    }
}

/// Bound the contact fan-out for #34. TDLib's `getContacts` has no server-side
/// limit (unlike `getChats` / `searchChats`), so it returns every contact id;
/// this caps the expensive one-`getUser`-per-id loop client-side. Pure +
/// testable seam (the fan-out itself needs a live TDLib connection, so this is
/// where #34's falsifiable coverage lives — see `TDLibClientContactsTests`).
/// The MCP handler refuses a limit outside 1...10_000 (`parseLimit`), but
/// `getContacts(limit:)` is public: the limit is clamped to 0...10_000 here,
/// so a negative one returns nothing instead of trapping in `prefix`.
internal func boundedContactIds(_ ids: [Int64], limit: Int) -> [Int64] {
    Array(ids.prefix(min(max(limit, 0), 10_000)))
}
