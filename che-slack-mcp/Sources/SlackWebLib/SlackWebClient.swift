import Foundation

/// Calls the Slack Web API as the signed-in user with a browser session
/// credential (spec: slack-web-client).
public struct SlackWebClient: Sendable {
    public static let baseURL = URL(string: "https://slack.com/api/")!

    /// How many times one call is retried after `rateLimited` before the
    /// error is thrown (spec: slack-web-client, "Rate limit retry").
    public static let maxRateLimitRetries = 3

    private let transport: SlackTransport
    private let clock: SlackClock
    /// Shared by every copy of this client, so copies pace together.
    let pacer: SlackPacer

    /// `pacing` is usually `SlackPacingConfig.fromEnvironment()`. `clock` is
    /// injectable so tests run waits on virtual time.
    public init(transport: SlackTransport = URLSessionTransport(),
                pacing: SlackPacingConfig = .default,
                clock: SlackClock = SystemSlackClock()) {
        self.transport = transport
        self.clock = clock
        self.pacer = SlackPacer(config: pacing, clock: clock)
    }

    /// Builds the POST for `method`: the token goes in the form body, the
    /// cookie in the `Cookie` header, and neither in the URL. Parameters
    /// follow the token in name order so the body is deterministic. Cookie
    /// handling is off, so the URL loading system neither adds a stored
    /// cookie to this header nor stores one from the answer.
    public func request(method: String, parameters: [String: String], credential: SlackCredential) -> URLRequest {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.setValue("d=\(credential.cookie)", forHTTPHeaderField: "Cookie")
        let fields = [("token", credential.token)] + parameters.sorted { $0.key < $1.key }
        let body = fields.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Sends `method` and returns the raw response body once the answer is
    /// HTTP 200 with `"ok": true`; otherwise throws a `SlackError` (see
    /// `SlackResponseClassifier` for the full table). A `rateLimited` answer
    /// is retried after its `Retry-After` wait, up to
    /// `maxRateLimitRetries` times; after that the last answer's wait is
    /// thrown without waiting it. Every attempt, retries included, goes
    /// through the workspace's pacing; the `Retry-After` wait itself holds no
    /// concurrency slot. Cancellation propagates as `CancellationError`.
    public func call(_ method: String, parameters: [String: String], credential: SlackCredential) async throws -> Data {
        let request = request(method: method, parameters: parameters, credential: credential)
        var retries = 0
        while true {
            switch try await attempt(request, credential: credential) {
            case let .success(data):
                return data
            case let .failure(.rateLimited(seconds)) where retries < Self.maxRateLimitRetries:
                retries += 1
                try await clock.sleep(for: .seconds(seconds))
            case let .failure(error):
                throw error
            }
        }
    }

    /// One paced send and its classification. Throws only
    /// `CancellationError`.
    private func attempt(_ request: URLRequest, credential: SlackCredential) async throws -> Result<Data, SlackError> {
        let workspace = credential.teamID
        try await pacer.acquire(workspace: workspace)
        let sent: Result<(Data, HTTPURLResponse), Error>
        do {
            sent = .success(try await transport.send(request))
        } catch {
            sent = .failure(error)
        }
        await pacer.release(workspace: workspace)

        switch sent {
        case let .failure(error) where error is CancellationError:
            throw error
        case let .failure(error):
            return .failure(SlackError.network(error.localizedDescription).redacting(credential))
        case let .success((data, response)):
            return SlackResponseClassifier.classify(
                status: response.statusCode,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                body: data,
                workspace: workspace)
                .mapError { $0.redacting(credential) }
        }
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
