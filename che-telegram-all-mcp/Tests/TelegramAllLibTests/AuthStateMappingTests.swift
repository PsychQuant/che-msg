import XCTest
import TDLibKit
@testable import TelegramAllLib

/// Which TDLib authorization states the client tracks (PsychQuant/che-msg#64).
/// Logging out and closing were not tracked, so `auth_status` kept reporting
/// `ready` until TDLib had closed. Both are now `closing`; `closed` still means
/// TDLib has finished closing, which is what `close(timeout:)` and the
/// lifecycle wait for before releasing the lock.
final class AuthStateMappingTests: XCTestCase {
    func testLoggingOutAndClosingAreClosing() {
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateLoggingOut), .closing)
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateClosing), .closing)
    }

    func testClosedStillMeansFinishedClosing() {
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateClosed), .closed)
    }

    func testTheLoginStatesAreUnchanged() {
        let code = AuthorizationStateWaitCode(codeInfo: AuthenticationCodeInfo(
            nextType: nil, phoneNumber: "+886900000000", timeout: 60,
            type: .authenticationCodeTypeSms(AuthenticationCodeTypeSms(length: 5))))
        let password = AuthorizationStateWaitPassword(hasPassportData: false, hasRecoveryEmailAddress: false,
                                                      passwordHint: "", recoveryEmailAddressPattern: "")
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateWaitTdlibParameters), .waitingForParameters)
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateWaitPhoneNumber), .waitingForPhoneNumber)
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateWaitCode(code)), .waitingForCode)
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateWaitPassword(password)), .waitingForPassword)
        XCTAssertEqual(TDLibClient.authState(for: .authorizationStateReady), .ready)
    }

    /// A state the client has no value for leaves the current one as it is.
    func testAStateTheClientDoesNotTrackIsNotMapped() {
        XCTAssertNil(TDLibClient.authState(for: .authorizationStateWaitOtherDeviceConfirmation(
            AuthorizationStateWaitOtherDeviceConfirmation(link: "tg://login?token=x"))))
    }
}
