import Foundation
import SlackWebLib

/// `localConfig_v2`, the localStorage item of `app.slack.com` in which the
/// Slack desktop app keeps its signed-in workspaces. Every error is a fixed
/// phrase: the item holds tokens, so nothing read from it is ever quoted.
enum SlackLocalConfig {
    static let origin = Array("_https://app.slack.com".utf8)
    static let name = Array("localConfig_v2".utf8)

    /// True for Chromium's localStorage key of this item: `_`, the origin,
    /// a 0 separator, an optional 1 (the key's Latin-1 marker), the name.
    static func isKey(_ key: [UInt8]) -> Bool {
        guard key.count >= origin.count + 1 + name.count,
              key.starts(with: origin), key[origin.count] == 0, key.suffix(name.count).elementsEqual(name) else {
            return false
        }
        let marker = key[(origin.count + 1)..<(key.count - name.count)]
        return marker.isEmpty || marker.elementsEqual([1])
    }

    /// The value as text: its first byte says how the rest is encoded,
    /// 1 Latin-1 or 0 UTF-16 little-endian.
    static func text(of value: [UInt8]) throws -> String {
        guard let marker = value.first else { throw DesktopFormatError("localConfig_v2 is empty") }
        let body = value.dropFirst()
        switch marker {
        case 1:
            return String(String.UnicodeScalarView(body.map { Unicode.Scalar($0) }))
        case 0:
            guard body.count % 2 == 0 else { throw DesktopFormatError("localConfig_v2 is not valid UTF-16") }
            let units = stride(from: body.startIndex, to: body.endIndex, by: 2).map {
                UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8
            }
            var text = String.UnicodeScalarView()
            var iterator = units.makeIterator()
            var decoder = UTF16()
            while true {
                switch decoder.decode(&iterator) {
                case .scalarValue(let scalar): text.append(scalar)
                case .emptyInput: return String(text)
                case .error: throw DesktopFormatError("localConfig_v2 is not valid UTF-16")
                }
            }
        default:
            throw DesktopFormatError("localConfig_v2 has an unknown text encoding")
        }
    }

    /// The workspaces in `teams`: one candidate per team with string `id`,
    /// `domain`, `name`, `token` and `user_id` (other keys are ignored),
    /// sorted by team id, and how many teams lacked one of them.
    ///
    /// - Throws: `DesktopFormatError` when the text is not a JSON object
    ///   with a `teams` object, or no team is complete.
    static func candidates(from json: String) throws -> (candidates: [ImportCandidate], skipped: Int) {
        guard let config = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
            throw DesktopFormatError("localConfig_v2 is not a JSON object with a teams object")
        }
        let complete = config.teams.values.compactMap { $0.candidate }.sorted { $0.workspace.teamID < $1.workspace.teamID }
        guard !complete.isEmpty else {
            throw DesktopFormatError("localConfig_v2 lists no workspace with id, domain, name, token and user_id")
        }
        return (complete, config.teams.count - complete.count)
    }

    private struct Config: Decodable {
        let teams: [String: Team]
    }

    /// A team entry; any field that is missing or not a string is nil, and
    /// an entry that is not an object has every field nil.
    private struct Team: Decodable {
        let id, domain, name, token, userID: String?

        enum CodingKeys: String, CodingKey {
            case id, domain, name, token
            case userID = "user_id"
        }

        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String? { (try? fields?.decodeIfPresent(String.self, forKey: key)) ?? nil }
            id = string(.id)
            domain = string(.domain)
            name = string(.name)
            token = string(.token)
            userID = string(.userID)
        }

        var candidate: ImportCandidate? {
            guard let id, let domain, let name, let token, let userID else { return nil }
            return ImportCandidate(workspace: SlackWorkspace(teamID: id, domain: domain, name: name, userID: userID), token: token)
        }
    }
}
