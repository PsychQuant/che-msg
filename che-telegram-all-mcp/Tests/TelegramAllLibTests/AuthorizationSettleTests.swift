import XCTest
@testable import TelegramAllLib

/// A client opened on demand must not answer its first call while TDLib is
/// still logging in (PsychQuant/che-msg#58): the server waits until
/// authorization has gone as far as it can without a caller.
final class AuthorizationSettleTests: XCTestCase {
    private func settled(_ state: TDLibClient.AuthState, error: Bool = false, apiId: Int? = nil, apiHash: String? = nil,
                         phone: String? = nil, password: String? = nil,
                         keychain: CredentialLookupStatus = .notNeeded) -> Bool {
        authorizationIsSettled(state: state, hasAutoFireError: error, envApiId: apiId, envApiHash: apiHash,
                               envPhone: phone, envPassword: password, keychainLookup: keychain)
    }

    func testReadyAndClosedAreSettled() {
        XCTAssertTrue(settled(.ready, apiId: 1, apiHash: "h"))
        XCTAssertTrue(settled(.closed, apiId: 1, apiHash: "h"))
    }

    func testParametersStillToBeSentAutomaticallyAreNotSettled() {
        XCTAssertFalse(settled(.waitingForParameters, apiId: 1, apiHash: "h"))
        XCTAssertTrue(settled(.waitingForParameters))
    }

    func testPhoneAndPasswordWaitOnlyWhileTheEnvironmentCanSupplyThem() {
        XCTAssertFalse(settled(.waitingForPhoneNumber, phone: "+886900000000"))
        XCTAssertTrue(settled(.waitingForPhoneNumber))
        XCTAssertFalse(settled(.waitingForPassword, password: "pw"))
        XCTAssertTrue(settled(.waitingForPassword))
    }

    func testCodeNeedsACallerSoItIsSettled() {
        XCTAssertTrue(settled(.waitingForCode, apiId: 1, apiHash: "h", phone: "+886900000000", password: "pw"))
    }

    func testAFailedAutomaticStepIsSettled() {
        XCTAssertTrue(settled(.waitingForParameters, error: true, apiId: 1, apiHash: "h"))
    }

    // MARK: - Keychain lookup (PsychQuant/che-msg#49; spec example "settled by lookup status")

    func testALookupInProgressIsNotSettled() {
        XCTAssertFalse(settled(.waitingForPassword, keychain: .pending))
        XCTAssertFalse(settled(.waitingForPhoneNumber, keychain: .pending))
    }

    func testAFoundValueBeingSubmittedIsNotSettled() {
        XCTAssertFalse(settled(.waitingForPassword, keychain: .found))
    }

    func testNoValueInTheKeychainIsSettled() {
        XCTAssertTrue(settled(.waitingForPassword, keychain: .absent))
        XCTAssertTrue(settled(.waitingForPhoneNumber, keychain: .absent))
    }

    func testAFailedSubmissionOfAKeychainValueIsSettled() {
        XCTAssertTrue(settled(.waitingForPassword, error: true, keychain: .found))
    }

    func testAnEnvironmentValueStillWaitsWithoutALookup() {
        XCTAssertFalse(settled(.waitingForPhoneNumber, phone: "+886900000000", keychain: .notNeeded))
    }

    func testCodeIsSettledWhateverTheLookupSays() {
        XCTAssertTrue(settled(.waitingForCode, keychain: .notNeeded))
    }
}
