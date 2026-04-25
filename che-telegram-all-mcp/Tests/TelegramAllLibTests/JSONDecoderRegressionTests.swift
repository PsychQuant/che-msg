import XCTest
import TDLibKit
@testable import TelegramAllLib

/// Covers spec requirement: "JSONDecoder snake_case invariant for TDLib updates"
/// Corresponds to design Decision 4.
///
/// Locks down the v0.2.0 critical bug regression path: the `JSONDecoder` used to
/// decode TDLib `Update` broadcasts MUST be configured with
/// `keyDecodingStrategy = .convertFromSnakeCase`. Without it, snake_case payloads
/// (`authorization_state`, etc.) silently fail to decode, freezing `authState` at
/// `.waitingForParameters` regardless of TDLib's real state machine.
///
/// We test indirectly — feed a known snake_case fixture through the decoder
/// returned by `makeUpdateDecoder()` and assert the decoded value matches the
/// expected case. `JSONDecoder.keyDecodingStrategy` lacks Equatable conformance,
/// so direct introspection isn't possible.
final class JSONDecoderRegressionTests: XCTestCase {

    func testSnakeCaseAuthorizationUpdateDecodesToWaitTdlibParameters() throws {
        let json = #"""
        {"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitTdlibParameters"}}
        """#
        let data = Data(json.utf8)

        let decoder = makeUpdateDecoder()
        let update = try decoder.decode(Update.self, from: data)

        guard case .updateAuthorizationState(let payload) = update else {
            XCTFail("Expected .updateAuthorizationState, got \(update)")
            return
        }

        guard case .authorizationStateWaitTdlibParameters = payload.authorizationState else {
            XCTFail("Expected .authorizationStateWaitTdlibParameters, got \(payload.authorizationState)")
            return
        }
    }

    func testSnakeCaseAuthorizationUpdateDecodesToWaitPhoneNumber() throws {
        let json = #"""
        {"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitPhoneNumber"}}
        """#
        let data = Data(json.utf8)

        let decoder = makeUpdateDecoder()
        let update = try decoder.decode(Update.self, from: data)

        guard case .updateAuthorizationState(let payload) = update,
              case .authorizationStateWaitPhoneNumber = payload.authorizationState else {
            XCTFail("Expected updateAuthorizationState(.authorizationStateWaitPhoneNumber), got \(update)")
            return
        }
    }

    /// Belt-and-braces: even camelCase keys SHOULD work because `.convertFromSnakeCase`
    /// only operates on snake_case input. Codable property already maps to camelCase,
    /// so identity input must also decode.
    func testCamelCaseAuthorizationStateAlsoDecodes() throws {
        // TDLib server emits snake_case in practice, but having identity-form decode
        // confirms the strategy doesn't mangle already-camelCase keys.
        let json = #"""
        {"@type":"updateAuthorizationState","authorizationState":{"@type":"authorizationStateReady"}}
        """#
        let data = Data(json.utf8)

        let decoder = makeUpdateDecoder()
        let update = try decoder.decode(Update.self, from: data)

        guard case .updateAuthorizationState(let payload) = update,
              case .authorizationStateReady = payload.authorizationState else {
            XCTFail("Expected updateAuthorizationState(.authorizationStateReady), got \(update)")
            return
        }
    }
}
