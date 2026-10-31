import XCTest
@testable import CheTelegramAllMCPCore
@testable import TelegramAllLib

/// Covers spec requirement: "`auth_run` MCP tool drives the state machine"
/// Corresponds to design Decision 4: `auth_run` MCP tool — state-machine driver.
///
/// Tests target the file-scope routing helper `decideAuthRunAction(...)`, which
/// returns a pure decision based on (current authState, caller args, env vars).
/// The Server's `case "auth_run"` handler dispatches on this decision.
///
/// Why a pure helper instead of stubbing TDLibClient: instantiating either
/// `TDLibClient` or the MCP Server boots a TDLib subprocess (process-global
/// receive loop). The state-machine logic itself is deterministic and has
/// nothing to do with TDLib I/O — extracting it keeps the test fast and
/// hermetic, matching the pattern used by AuthErrorResponseTests.
final class AuthRunHandlerTests: XCTestCase {

    // MARK: - waitingForParameters

    func testWaitingForParameters_withEnvCredentials_routesToAutoSet() {
        let action = decideAuthRunAction(
            state: .waitingForParameters,
            phone: nil, code: nil, password: nil,
            envApiId: 12345, envApiHash: "abcdef",
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .callSetParameters(apiId: 12345, apiHash: "abcdef"))
    }

    func testWaitingForParameters_withoutEnvCredentials_returnsNextStepHint() {
        let action = decideAuthRunAction(
            state: .waitingForParameters,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .needsArgs(["api_id", "api_hash"]))
    }

    // MARK: - waitingForPhoneNumber

    func testWaitingForPhone_withCallerArg_routesToSendPhone() {
        let action = decideAuthRunAction(
            state: .waitingForPhoneNumber,
            phone: "+886912345678", code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .callSendPhone("+886912345678"))
    }

    func testWaitingForPhone_withEnvVar_routesToSendPhoneFromEnv() {
        let action = decideAuthRunAction(
            state: .waitingForPhoneNumber,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: "+886900000000", envPassword: nil
        )
        XCTAssertEqual(action, .callSendPhone("+886900000000"))
    }

    func testWaitingForPhone_withoutAnyPhone_returnsNextStepHint() {
        let action = decideAuthRunAction(
            state: .waitingForPhoneNumber,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .needsArgs(["phone"]))
    }

    // MARK: - waitingForCode (env var MUST NOT be honored — spec)

    func testWaitingForCode_withCallerArg_routesToSendCode() {
        let action = decideAuthRunAction(
            state: .waitingForCode,
            phone: nil, code: "12345", password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .callSendCode("12345"))
    }

    func testWaitingForCode_withoutCallerArg_returnsNextStepHint() {
        // Even if env had TELEGRAM_AUTH_CODE, spec says it MUST NOT be honored.
        // Here we don't even have a knob for it — by construction it's caller-only.
        let action = decideAuthRunAction(
            state: .waitingForCode,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .needsArgs(["code"]))
    }

    // MARK: - waitingForPassword

    func testWaitingForPassword_withCallerArg_routesToSendPassword() {
        let action = decideAuthRunAction(
            state: .waitingForPassword,
            phone: nil, code: nil, password: "secret",
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .callSendPassword("secret"))
    }

    func testWaitingForPassword_withEnvVar_routesToSendPasswordFromEnv() {
        let action = decideAuthRunAction(
            state: .waitingForPassword,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: "envSecret"
        )
        XCTAssertEqual(action, .callSendPassword("envSecret"))
    }

    func testWaitingForPassword_withoutAnyPassword_returnsNextStepHint() {
        let action = decideAuthRunAction(
            state: .waitingForPassword,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .needsArgs(["password"]))
    }

    // MARK: - Ready / Closed

    func testReady_returnsNoOp() {
        let action = decideAuthRunAction(
            state: .ready,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .noOpReady)
    }

    func testClosed_returnsErrorClosed() {
        let action = decideAuthRunAction(
            state: .closed,
            phone: nil, code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: nil
        )
        XCTAssertEqual(action, .errorClosed)
    }

    // MARK: - Argument precedence (caller arg overrides env var)

    func testCallerArgOverridesEnvVarForPhone() {
        let action = decideAuthRunAction(
            state: .waitingForPhoneNumber,
            phone: "+886912345678", code: nil, password: nil,
            envApiId: nil, envApiHash: nil,
            envPhone: "+886900000000", envPassword: nil
        )
        XCTAssertEqual(action, .callSendPhone("+886912345678"),
                       "Caller-supplied phone MUST take precedence over env var")
    }

    func testCallerArgOverridesEnvVarForPassword() {
        let action = decideAuthRunAction(
            state: .waitingForPassword,
            phone: nil, code: nil, password: "callerSecret",
            envApiId: nil, envApiHash: nil,
            envPhone: nil, envPassword: "envSecret"
        )
        XCTAssertEqual(action, .callSendPassword("callerSecret"),
                       "Caller-supplied password MUST take precedence over env var")
    }

    // MARK: - Keychain as the third source (PsychQuant/che-msg#49; spec example "source precedence")

    private func phoneAction(arg: String?, env: String?, keychain: String?) -> AuthRunAction {
        decideAuthRunAction(state: .waitingForPhoneNumber, phone: arg, code: nil, password: nil,
                            envApiId: nil, envApiHash: nil, envPhone: env, envPassword: nil,
                            keychainPhone: keychain, keychainPassword: nil)
    }

    private func passwordAction(arg: String?, env: String?, keychain: String?) -> AuthRunAction {
        decideAuthRunAction(state: .waitingForPassword, phone: nil, code: nil, password: arg,
                            envApiId: nil, envApiHash: nil, envPhone: nil, envPassword: env,
                            keychainPhone: nil, keychainPassword: keychain)
    }

    func testPhonePrecedence_callerArgumentWins() {
        XCTAssertEqual(phoneAction(arg: "+886911111111", env: "+886922222222", keychain: "+886933333333"),
                       .callSendPhone("+886911111111"))
    }

    func testPhonePrecedence_environmentBeatsKeychain() {
        XCTAssertEqual(phoneAction(arg: nil, env: "+886922222222", keychain: "+886933333333"),
                       .callSendPhone("+886922222222"))
    }

    func testPhonePrecedence_keychainWhenNothingElse() {
        XCTAssertEqual(phoneAction(arg: nil, env: nil, keychain: "+886933333333"), .callSendPhone("+886933333333"))
    }

    func testPhonePrecedence_nothingAnywhereNeedsTheArgument() {
        XCTAssertEqual(phoneAction(arg: nil, env: nil, keychain: nil), .needsArgs(["phone"]))
    }

    func testPasswordPrecedence() {
        XCTAssertEqual(passwordAction(arg: "from-arg", env: "from-env", keychain: "from-keychain"), .callSendPassword("from-arg"))
        XCTAssertEqual(passwordAction(arg: nil, env: "from-env", keychain: "from-keychain"), .callSendPassword("from-env"))
        XCTAssertEqual(passwordAction(arg: nil, env: nil, keychain: "from-keychain"), .callSendPassword("from-keychain"))
        XCTAssertEqual(passwordAction(arg: nil, env: nil, keychain: nil), .needsArgs(["password"]))
    }

    /// Spec: the Keychain is never consulted for the SMS code.
    func testCodeIgnoresKeychainValues() {
        let action = decideAuthRunAction(state: .waitingForCode, phone: nil, code: nil, password: nil,
                                         envApiId: nil, envApiHash: nil, envPhone: nil, envPassword: nil,
                                         keychainPhone: "+886933333333", keychainPassword: "from-keychain")
        XCTAssertEqual(action, .needsArgs(["code"]))
    }

    func testParametersIgnoreKeychainValues() {
        let action = decideAuthRunAction(state: .waitingForParameters, phone: nil, code: nil, password: nil,
                                         envApiId: nil, envApiHash: nil, envPhone: nil, envPassword: nil,
                                         keychainPhone: "+886933333333", keychainPassword: "from-keychain")
        XCTAssertEqual(action, .needsArgs(["api_id", "api_hash"]))
    }

    // MARK: - When auth_run reads the Keychain at all

    func testKeychainIsReadOnlyWhenArgumentAndEnvironmentAreBothMissing() {
        XCTAssertEqual(authRunKeychainLookup(state: .waitingForPhoneNumber, phone: nil, password: nil,
                                             envPhone: nil, envPassword: nil), .phone)
        XCTAssertEqual(authRunKeychainLookup(state: .waitingForPassword, phone: nil, password: nil,
                                             envPhone: nil, envPassword: nil), .password)
        XCTAssertNil(authRunKeychainLookup(state: .waitingForPhoneNumber, phone: "+886911111111", password: nil,
                                           envPhone: nil, envPassword: nil))
        XCTAssertNil(authRunKeychainLookup(state: .waitingForPhoneNumber, phone: nil, password: nil,
                                           envPhone: "+886922222222", envPassword: nil))
        XCTAssertNil(authRunKeychainLookup(state: .waitingForPassword, phone: nil, password: "pw",
                                           envPhone: nil, envPassword: nil))
        XCTAssertNil(authRunKeychainLookup(state: .waitingForPassword, phone: nil, password: nil,
                                           envPhone: nil, envPassword: "pw"))
    }

    func testKeychainIsNeverReadForTheCodeOrOtherStates() {
        for state in [TDLibClient.AuthState.waitingForCode, .waitingForParameters, .ready, .closed] {
            XCTAssertNil(authRunKeychainLookup(state: state, phone: nil, password: nil, envPhone: nil, envPassword: nil),
                         "\(state)")
        }
    }

    // MARK: - A Keychain value read before the state moved on (verify round 1)

    func testAKeychainValueIsUsedWhileTheStateStillAsksForIt() {
        let values = authRunKeychainValues(lookedUp: .password, value: "from-keychain", stateNow: .waitingForPassword,
                                           phone: nil, password: nil, envPhone: nil, envPassword: nil)
        XCTAssertEqual(values.phone, nil)
        XCTAssertEqual(values.password, "from-keychain")
    }

    func testAKeychainValueIsDroppedWhenTheStateMovedOn() {
        for stateNow in [TDLibClient.AuthState.ready, .waitingForCode, .waitingForPhoneNumber, .closed] {
            let values = authRunKeychainValues(lookedUp: .password, value: "from-keychain", stateNow: stateNow,
                                               phone: nil, password: nil, envPhone: nil, envPassword: nil)
            XCTAssertNil(values.password, "\(stateNow)")
            XCTAssertNil(values.phone, "\(stateNow)")
        }
    }

    func testNothingLookedUpGivesNoKeychainValues() {
        let values = authRunKeychainValues(lookedUp: nil, value: nil, stateNow: .waitingForPhoneNumber,
                                           phone: nil, password: nil, envPhone: nil, envPassword: nil)
        XCTAssertNil(values.phone)
        XCTAssertNil(values.password)
    }

    // MARK: - Routing after the lookup (#49 verify r2)

    private func afterLookup(_ lookedUp: KeychainCredential?, _ value: String?, now: TDLibClient.AuthState,
                             code: String? = nil) -> AuthRunAction {
        decideAuthRunActionAfterLookup(lookedUp: lookedUp, value: value, stateNow: now, phone: nil, code: code,
                                       password: nil, envApiId: 1, envApiHash: "h", envPhone: nil, envPassword: nil)
    }

    func testAfterTheLookupTheActionFollowsTheStateAsItIsNow() {
        XCTAssertEqual(afterLookup(.password, "from-keychain", now: .waitingForPassword), .callSendPassword("from-keychain"))
        XCTAssertEqual(afterLookup(.password, "from-keychain", now: .ready), .noOpReady,
                       "the background step already logged in: nothing is sent again")
        XCTAssertEqual(afterLookup(.phone, "+886912345678", now: .waitingForCode, code: nil),
                       decideAuthRunAction(state: .waitingForCode, phone: nil, code: nil, password: nil,
                                           envApiId: 1, envApiHash: "h", envPhone: nil, envPassword: nil),
                       "a phone number found for an earlier state is not sent at waitingForCode")
    }

    // MARK: - Descriptions never carry a value (#96)

    func testAnActionNeverPrintsItsValue() {
        let actions: [AuthRunAction] = [
            .callSetParameters(apiId: 12345, apiHash: "hash-value"), .callSendPhone("+886900000417"),
            .callSendCode("54321"), .callSendPassword("secret-2fa"),
        ]
        for action in actions {
            for text in ["\(action)", String(reflecting: action)] {
                for value in ["hash-value", "886900000417", "54321", "secret-2fa"] {
                    XCTAssertFalse(text.contains(value), text)
                }
            }
        }
        XCTAssertEqual("\(AuthRunAction.callSendPassword("x"))", "callSendPassword(<redacted>)")
        XCTAssertEqual("\(AuthRunAction.callSetParameters(apiId: 12345, apiHash: "h"))", "callSetParameters(apiId: 12345, apiHash: <redacted>)")
        XCTAssertEqual("\(AuthRunAction.needsArgs(["phone"]))", "needsArgs([\"phone\"])")
    }
}

