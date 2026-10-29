import Foundation

/// `<output_dir>/<team_id>/<conversation_id>/manifest.json` (spec:
/// slack-chat-archive, "Incremental archive and manifest"): the bookmarks
/// of one conversation's archive. It holds ids, ts, a time and counts, and
/// never message text, sender names or file names.
///
///     {
///       "conversation_id" : "C01",
///       "format" : "che-slack-mcp archive manifest",
///       "last_run" : {
///         "at" : "2026-11-01T11:05:00+08:00",
///         "new_messages" : 2,
///         "thread_replies" : 1,
///         "top_level_messages" : 1
///       },
///       "newest_reply_ts" : {
///         "1793498700.000100" : "1793498820.000200"
///       },
///       "newest_ts" : "1793498700.000100",
///       "team_id" : "T01",
///       "version" : 1
///     }
///
/// - `newest_ts`: the newest top-level ts archived, or null. It is moved
///   only by a run whose history walk reached its lower bound, so every
///   message between the old and the new value was read.
/// - `newest_reply_ts`: per thread parent whose ts is inside the last run's
///   lookback window, the newest reply ts archived for it.
/// - `last_run`: the run's start, at the run's `utc_offset`, and the counts
///   the run returned.
///
/// A run stopped by a rate limit or ended by an error does not write the
/// manifest, so none of these moves: the next run reads that range again.
struct ArchiveManifest: Codable, Equatable {
    static let formatName = "che-slack-mcp archive manifest"
    static let currentVersion = 1

    struct LastRun: Codable, Equatable {
        let at: String
        let top_level_messages: Int
        let thread_replies: Int
        let new_messages: Int
    }

    let format: String
    let version: Int
    let team_id: String
    let conversation_id: String
    let newest_ts: String?
    let newest_reply_ts: [String: String]
    let last_run: LastRun

    enum CodingKeys: String, CodingKey {
        case format, version, team_id, conversation_id, newest_ts, newest_reply_ts, last_run
    }

    init(teamID: String, conversationID: String, newestTS: String?, newestReplyTS: [String: String],
         lastRun: LastRun) {
        format = Self.formatName
        version = Self.currentVersion
        team_id = teamID
        conversation_id = conversationID
        newest_ts = newestTS
        newest_reply_ts = newestReplyTS
        last_run = lastRun
    }

    /// Every field is required, `newest_ts` too (as a string or null), so
    /// a manifest missing its bookmark is refused rather than read as a
    /// first run. A field of another JSON type fails the whole manifest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        team_id = try container.decode(String.self, forKey: .team_id)
        conversation_id = try container.decode(String.self, forKey: .conversation_id)
        newest_ts = try container.decode(String?.self, forKey: .newest_ts)
        newest_reply_ts = try container.decode([String: String].self, forKey: .newest_reply_ts)
        last_run = try container.decode(LastRun.self, forKey: .last_run)
    }

    /// `newest_ts` is written as null rather than left out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(team_id, forKey: .team_id)
        try container.encode(conversation_id, forKey: .conversation_id)
        try container.encode(newest_ts, forKey: .newest_ts)
        try container.encode(newest_reply_ts, forKey: .newest_reply_ts)
        try container.encode(last_run, forKey: .last_run)
    }

    /// The file's bytes: sorted keys, two-space indent, a final newline.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Strings, integers and a string map: encoding cannot fail.
        let data = (try? encoder.encode(self)) ?? Data()
        return data + Data("\n".utf8)
    }

    /// `date` written `yyyy-MM-dd'T'HH:mm:ssxxx` at `offsetSeconds`, such as
    /// `2026-11-01T11:05:00+08:00`: always with an explicit offset.
    static func timestamp(_ date: Date, offsetSeconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }
}

extension ArchiveDirectory {
    /// The largest manifest read, in bytes.
    static let maxManifestBytes = 8 << 20

    var manifestFile: URL { conversationDir.appendingPathComponent("manifest.json") }

    /// The manifest, or nil when there is none (a first run, which reads
    /// the whole history). Never resets silently: a manifest that is not a
    /// regular file, cannot be read, is larger than `maxManifestBytes`, is
    /// not JSON in the shape `ArchiveManifest` writes, names another format,
    /// version, workspace or conversation, or holds a ts that is not a
    /// Slack timestamp refuses the call before Slack is called.
    func readManifest() throws(ToolFailure) -> ArchiveManifest? {
        guard try Self.checkRegularFile(manifestFile) else { return nil }
        let data = try readManifestData()
        guard let manifest = try? JSONDecoder().decode(ArchiveManifest.self, from: data) else {
            throw manifestRefusal("is not JSON in the shape this tool writes")
        }
        guard manifest.format == ArchiveManifest.formatName, manifest.version == ArchiveManifest.currentVersion else {
            throw manifestRefusal("is not a \(ArchiveManifest.formatName) of version \(ArchiveManifest.currentVersion)")
        }
        guard manifest.team_id == teamID, manifest.conversation_id == conversationID else {
            throw manifestRefusal("records another workspace or conversation than \(teamID)/\(conversationID)")
        }
        let isTS = { (ts: String) in SlackDayFile.seconds(ofTS: ts) != nil }
        guard manifest.newest_ts.map(isTS) ?? true,
              manifest.newest_reply_ts.allSatisfy({ isTS($0.key) && isTS($0.value) }) else {
            throw manifestRefusal("holds a ts that is not a Slack timestamp")
        }
        return manifest
    }

    private func readManifestData() throws(ToolFailure) -> Data {
        guard let handle = FileHandle(forReadingAtPath: manifestFile.path) else {
            throw manifestRefusal("cannot be opened for reading")
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maxManifestBytes + 1) ?? Data()
        } catch {
            throw manifestRefusal("cannot be read")
        }
        guard data.count <= Self.maxManifestBytes else {
            throw manifestRefusal("is larger than \(Self.maxManifestBytes) bytes")
        }
        return data
    }

    private func manifestRefusal(_ reason: String) -> ToolFailure {
        ToolFailure("The manifest \(manifestFile.path) \(reason). It was left as it is and nothing was archived; "
                    + "restore it, or move it aside to archive the whole history again.")
    }

    /// Replaces the manifest atomically (0600, as a day file), creating the
    /// directories first when this run wrote no day file.
    func writeManifest(_ manifest: ArchiveManifest) throws(ToolFailure) {
        try createDirectories()
        try Self.replace(manifestFile, with: manifest.encoded()) { code in
            ToolFailure("Could not write the manifest \(manifestFile.path): \(String(cString: strerror(code))). The "
                        + "day files written in this call are kept; the manifest still holds the previous "
                        + "bookmark, so the next call reads those messages again and merges them in place.")
        }
    }
}
