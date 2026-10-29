import Foundation
import SlackWebLib

/// Direct-message names for one `list_conversations` call: each user is
/// looked up once, and at most `limit` distinct users are looked up.
///
/// A lookup that Slack answers with an ordinary error (`slackError`, such as
/// `user_not_found` for a user outside the workspace) names only that
/// entry. Any other failure (session, rate limit, Enterprise Grid, network,
/// cancellation) is thrown, since it would fail every later lookup too.
struct DirectMessageNames {
    struct Name: Equatable {
        let value: String?
        let error: String?
    }

    let limit: Int
    private var cache: [String: Name] = [:]

    init(limit: Int) { self.limit = limit }

    mutating func name(of user: String, lookup: () async throws -> SlackUser) async throws -> Name {
        if let known = cache[user] { return known }
        guard cache.count < limit else { return Name(value: nil, error: "lookup_limit") }
        let name: Name
        do {
            name = try await lookup().preferredName.map { Name(value: $0, error: nil) } ?? Name(value: nil, error: "no_name")
        } catch SlackError.slackError(let code) {
            name = Name(value: nil, error: code)
        }
        cache[user] = name
        return name
    }
}
