import XCTest
@testable import TelegramAllLib

/// Values that carry a credential print as `<redacted>` (PsychQuant/che-msg#96),
/// like `KeychainLookup`; and the `telegram-all` CLI never reads the Keychain.
final class CredentialRedactionTests: XCTestCase {
    func testACredentialPlanNeverPrintsItsValue() {
        let plan = CredentialPlan.fire("secret-2fa")
        XCTAssertFalse("\(plan)".contains("secret-2fa"), "\(plan)")
        XCTAssertFalse(String(reflecting: plan).contains("secret-2fa"), String(reflecting: plan))
        XCTAssertEqual("\(plan)", "fire(<redacted>)")
        XCTAssertEqual("\(CredentialPlan.lookUp(.password))", "lookUp(TELEGRAM_2FA_PASSWORD)")
        XCTAssertEqual("\(CredentialPlan.nothing)", "nothing")
    }

    func testAnAutoFireActionNeverPrintsItsValue() {
        let actions: [AutoFireAction] = [.fireSetParameters(apiId: 12345, apiHash: "hash-value"),
                                         .fireSendPhone("+886900000417"), .fireSendPassword("secret-2fa")]
        for action in actions {
            for text in ["\(action)", String(reflecting: action)] {
                for value in ["hash-value", "886900000417", "secret-2fa"] { XCTAssertFalse(text.contains(value), text) }
            }
        }
        XCTAssertEqual("\(AutoFireAction.fireSetParameters(apiId: 12345, apiHash: "h"))", "fireSetParameters(apiId: 12345, apiHash: <redacted>)")
    }

    func testAParsedPasswordLineNeverPrintsItsValue() {
        let line = SecurityCLICredentialSource.PasswordLine.value("secret-2fa")
        XCTAssertEqual("\(line)", "value(<redacted>)")
        XCTAssertFalse(String(reflecting: line).contains("secret-2fa"))
    }

    func testTheNoKeychainSourceFindsNothing() async {
        for credential in KeychainCredential.allCases {
            let result = await NoKeychainCredentialSource().lookup(credential)
            XCTAssertEqual(result, .absent)
        }
    }

    /// The CLI opens TDLib for every command; with the default source a
    /// stored phone number would be sent whenever the database is logged out.
    func testTheCLIOpensTDLibWithoutTheKeychain() throws {
        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/telegram-all")
        let files = try FileManager.default.contentsOfDirectory(at: cli, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var constructions = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("TDLibClient(") {
                constructions += 1
                XCTAssertTrue(line.contains("credentials: NoKeychainCredentialSource()"), "\(file.lastPathComponent): \(line)")
            }
        }
        XCTAssertEqual(constructions, 2, "makeClient and makeAuthedClient")
    }
}
