import Foundation

/// Calls the Slack Web API as the signed-in user with a browser session
/// credential (spec: slack-web-client).
public struct SlackWebClient: Sendable {
    public static let baseURL = URL(string: "https://slack.com/api/")!

    private let transport: SlackTransport

    public init(transport: SlackTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Builds the POST for `method`: the token goes in the form body, the
    /// cookie in the `Cookie` header, and neither in the URL. Parameters
    /// follow the token in name order so the body is deterministic.
    public func request(method: String, parameters: [String: String], credential: SlackCredential) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("d=\(credential.cookie)", forHTTPHeaderField: "Cookie")
        let fields = [("token", credential.token)] + parameters.sorted { $0.key < $1.key }
        let body = fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Sends `method` and returns the raw response body.
    public func call(_ method: String, parameters: [String: String], credential: SlackCredential) async throws -> Data {
        let (data, _) = try await transport.send(request(method: method, parameters: parameters, credential: credential))
        return data
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters.
    static func formEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(Unicode.Scalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
