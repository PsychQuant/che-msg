import Foundation

/// Errors from the read-only local reader (PsychQuant/che-msg#58).
///
/// Descriptions never contain key material: the reader handles the binlog key
/// and the SQLite key, and neither may reach a log, an MCP result, or stderr.
public enum LocalReaderError: Error, Equatable, CustomStringConvertible {
    /// The binlog holds no `sqlite_key` entry.
    case keyNotFound
    /// The binlog's encryption event does not match TDLib's default key.
    case wrongBinlogKey
    /// The binlog file could not be read.
    case binlogUnreadable(String)
    /// The TDLib build or the database format is not one the reader was verified against.
    case unsupportedTDLibVersion(String)
    /// The database could not be opened or queried.
    case databaseUnreadable(String)
    /// The TDLib directory is not logged in.
    case notAuthenticated

    public var description: String {
        switch self {
        case .keyNotFound: return "the TDLib binlog holds no sqlite_key"
        case .wrongBinlogKey: return "the TDLib binlog is not encrypted with TDLib's default key"
        case .binlogUnreadable(let reason): return "cannot read the TDLib binlog: \(reason)"
        case .unsupportedTDLibVersion(let detail): return "unsupported TDLib version: \(detail)"
        case .databaseUnreadable(let reason): return "cannot read the TDLib database: \(reason)"
        case .notAuthenticated: return "the TDLib database is not logged in to a Telegram account"
        }
    }

    /// The `reason` value of the `local_reader_unavailable` error JSON.
    public var reason: String {
        switch self {
        case .keyNotFound: return "key_not_found"
        case .wrongBinlogKey, .binlogUnreadable, .databaseUnreadable: return "database_unreadable"
        case .unsupportedTDLibVersion: return "unsupported_tdlib_version"
        case .notAuthenticated: return "not_authenticated"
        }
    }
}
