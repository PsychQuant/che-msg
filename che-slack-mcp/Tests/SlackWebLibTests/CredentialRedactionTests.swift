import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "No credential in output".
@Suite("No credential in output")
struct CredentialRedactionTests {
    let token = "xoxc-1111-2222-secret"
    let cookie = "xoxd-cookie%2Fsecret"
    var credential: SlackCredential { SlackCredential(teamID: "T0123ABCD", token: token, cookie: cookie) }

    @Test("String(describing:) names the workspace and redacts the token and cookie")
    func describingIsRedacted() {
        let output = String(describing: credential)

        #expect(output.contains("T0123ABCD"))
        #expect(output.contains("<redacted>"))
        #expect(!output.contains(token))
        #expect(!output.contains(cookie))
    }

    @Test("every other formatting path also redacts", arguments: FormattingPath.allCases)
    func otherFormattingPathsAreRedacted(path: FormattingPath) {
        let output = path.format(credential)

        #expect(output.contains("T0123ABCD"))
        #expect(output.contains("<redacted>"))
        #expect(!output.contains(token))
        #expect(!output.contains(cookie))
    }
}

/// The ways a value reaches text other than `String(describing:)`. Swift
/// Testing expands failing values through `String(describingForTest:)` and
/// `Mirror`, so both are covered.
enum FormattingPath: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case reflecting, interpolation, dumped, mirrorChildren, describingForTest

    var testDescription: String { rawValue }

    func format(_ credential: SlackCredential) -> String {
        switch self {
        case .reflecting:
            return String(reflecting: credential)
        case .interpolation:
            return "\(credential)"
        case .dumped:
            var out = ""
            dump(credential, to: &out)
            return out
        case .mirrorChildren:
            return Mirror(reflecting: credential).children
                .map { "\($0.label ?? "?")=\(String(describing: $0.value))" }
                .joined(separator: ",")
        case .describingForTest:
            return String(describingForTest: credential)
        }
    }
}
