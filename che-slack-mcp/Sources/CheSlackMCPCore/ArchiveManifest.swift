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
///   only by a run whose history walk reached its lower bound, and by an
///   explicit range only when that bound is at or before it, so every
///   message between the old and the new value was read.
/// - `newest_reply_ts`: per thread parent whose ts is inside the last run's
///   lookback window, or that is listed in `unfinished_threads` whatever its
///   age, the newest reply ts archived for it; the next request for that
///   thread's replies starts after it.
/// - `continuation` (only while a walk is unfinished, so absent from the
///   example): `{"top_ts": …, "below_ts": …}`, a walk from `top_ts` down
///   to `newest_ts` (to the oldest message when null) that the page limit
///   or a rate limit stopped after writing down to `below_ts`; see
///   `Continuation`.
/// - `range` (only while an explicit range is unfinished):
///   `{"oldest_ts": …, "newest_ts": … or null, "continuation": …}`, the
///   same pair as the manifest's own for one `after_ts` or `since_date`;
///   see `ExplicitRange`.
/// - `unfinished_threads` (only while there are any): the parents, oldest
///   first, whose replies the reply page limit cut; every run continues
///   them after their `newest_reply_ts`.
/// - `last_run`: the run's start, at the run's `utc_offset`, and the counts
///   the run returned.
///
/// A run ended by an error does not write the manifest, so none of these
/// moves and the next run reads that range again. A run stopped by a rate
/// limit writes it only when its `continuation` or `range` moved or it
/// wrote replies of a thread it cut, and then leaves `newest_ts` as it
/// was, and `newest_reply_ts` and `unfinished_threads` too, except that
/// each thread it cut whose replies it wrote is listed with the newest
/// reply written.
///
/// `version` stays 1: `continuation`, `range` and `unfinished_threads` are
/// optional, so a manifest written before they existed is read as having
/// no unfinished walk, range or thread, and a build that does not know
/// them ignores them and reads the unfinished range again from the top,
/// which skips nothing (an unfinished thread outside the window is then
/// left as it is, as before).
struct ArchiveManifest: Codable, Equatable {
    static let formatName = "che-slack-mcp archive manifest"
    static let currentVersion = 1

    /// An unfinished walk (spec: "Incremental archive and manifest"): the
    /// next run without `after_ts` or `since_date` continues it below
    /// `below_ts`, sent as `latest`, down to `newest_ts`, before reading
    /// anything newer; when it gets there, `newest_ts` becomes `top_ts`.
    /// Every top-level message from `below_ts` to `top_ts` was written,
    /// with the replies of the thread parents among them.
    struct Continuation: Codable, Equatable {
        /// The newest top-level ts the walk wrote.
        let top_ts: String
        /// The oldest top-level ts the walk wrote.
        let below_ts: String
    }

    /// An explicit range (`after_ts` or `since_date`) that has not caught
    /// up (spec: "Incremental archive and manifest"). A call with the same
    /// lower bound continues `continuation` below its `below_ts` down to
    /// `newest_ts` (to `oldest_ts` when null); when it gets there,
    /// `newest_ts` becomes the continuation's `top_ts`. A call that finds
    /// no continuation reads only the messages newer than `newest_ts`, and
    /// drops the record once it gets there.
    struct ExplicitRange: Codable, Equatable {
        /// The lower bound exactly as the call sent it as `oldest`: the
        /// `after_ts`, or the start of `since_date` in seconds.
        let oldest_ts: String
        /// The newest top-level ts the range wrote contiguously from
        /// `oldest_ts`, or null.
        let newest_ts: String?
        /// Where the range's walk continues.
        let continuation: Continuation?

        enum CodingKeys: String, CodingKey { case oldest_ts, newest_ts, continuation }
    }

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
    let continuation: Continuation?
    let range: ExplicitRange?
    let unfinished_threads: [String]
    let last_run: LastRun

    enum CodingKeys: String, CodingKey {
        case format, version, team_id, conversation_id, newest_ts, newest_reply_ts, continuation, range,
             unfinished_threads, last_run
    }

    init(teamID: String, conversationID: String, newestTS: String?, newestReplyTS: [String: String],
         continuation: Continuation? = nil, range: ExplicitRange? = nil, unfinishedThreads: [String] = [],
         lastRun: LastRun) {
        format = Self.formatName
        version = Self.currentVersion
        team_id = teamID
        conversation_id = conversationID
        newest_ts = newestTS
        newest_reply_ts = newestReplyTS
        self.continuation = continuation
        self.range = range
        unfinished_threads = unfinishedThreads
        last_run = lastRun
    }

    /// Every field is required, `newest_ts` too (as a string or null), so
    /// a manifest missing its bookmark is refused rather than read as a
    /// first run; only `continuation`, `range` and `unfinished_threads` may
    /// be absent (or null). A field of another JSON type fails the whole
    /// manifest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        team_id = try container.decode(String.self, forKey: .team_id)
        conversation_id = try container.decode(String.self, forKey: .conversation_id)
        newest_ts = try container.decode(String?.self, forKey: .newest_ts)
        newest_reply_ts = try container.decode([String: String].self, forKey: .newest_reply_ts)
        continuation = try container.decodeIfPresent(Continuation.self, forKey: .continuation)
        range = try container.decodeIfPresent(ExplicitRange.self, forKey: .range)
        unfinished_threads = try container.decodeIfPresent([String].self, forKey: .unfinished_threads) ?? []
        last_run = try container.decode(LastRun.self, forKey: .last_run)
    }

    /// `newest_ts` is written as null rather than left out; `continuation`
    /// and `range` are left out when there is none, `unfinished_threads`
    /// when it is empty.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(team_id, forKey: .team_id)
        try container.encode(conversation_id, forKey: .conversation_id)
        try container.encode(newest_ts, forKey: .newest_ts)
        try container.encode(newest_reply_ts, forKey: .newest_reply_ts)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encodeIfPresent(range, forKey: .range)
        if !unfinished_threads.isEmpty { try container.encode(unfinished_threads, forKey: .unfinished_threads) }
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

extension ArchiveManifest.ExplicitRange {
    /// As the manifest's own pair: `newest_ts` is required (as a string or
    /// null), only `continuation` may be absent (or null).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oldest_ts = try container.decode(String.self, forKey: .oldest_ts)
        newest_ts = try container.decode(String?.self, forKey: .newest_ts)
        continuation = try container.decodeIfPresent(ArchiveManifest.Continuation.self, forKey: .continuation)
    }

    /// `newest_ts` is written as null rather than left out; `continuation`
    /// is left out when there is none.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(oldest_ts, forKey: .oldest_ts)
        try container.encode(newest_ts, forKey: .newest_ts)
        try container.encodeIfPresent(continuation, forKey: .continuation)
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
    /// version, workspace or conversation, holds a ts that is not a Slack
    /// timestamp, a continuation whose `below_ts` is not newer than
    /// `newest_ts` and at most `top_ts`, or a range whose `newest_ts` is not
    /// newer than its `oldest_ts` or whose continuation's `below_ts` is not
    /// newer than both and at most `top_ts`, refuses the call before Slack
    /// is called.
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
        let isWalk = { (walk: ArchiveManifest.Continuation) in isTS(walk.top_ts) && isTS(walk.below_ts) }
        guard manifest.newest_ts.map(isTS) ?? true,
              manifest.newest_reply_ts.allSatisfy({ isTS($0.key) && isTS($0.value) }),
              manifest.continuation.map(isWalk) ?? true,
              manifest.range.map({ isTS($0.oldest_ts) && ($0.newest_ts.map(isTS) ?? true)
                                     && ($0.continuation.map(isWalk) ?? true) }) ?? true,
              manifest.unfinished_threads.allSatisfy(isTS) else {
            throw manifestRefusal("holds a ts that is not a Slack timestamp")
        }
        if let continuation = manifest.continuation {
            guard Self.continues(continuation, below: manifest.newest_ts) else {
                throw manifestRefusal("holds a continuation whose below_ts is not newer than newest_ts and at most "
                                      + "top_ts")
            }
        }
        if let range = manifest.range {
            guard range.newest_ts.map({ SlackDayFile.precedes(range.oldest_ts, $0) }) ?? true,
                  range.continuation.map({ Self.continues($0, below: range.newest_ts ?? range.oldest_ts) }) ?? true
            else {
                throw manifestRefusal("holds a range whose newest_ts is not newer than its oldest_ts, or whose "
                                      + "continuation's below_ts is not newer than both and at most top_ts")
            }
        }
        return manifest
    }

    /// Whether `walk` lies above `bound`: its `below_ts` is newer than
    /// `bound` (any, when nil) and not newer than its `top_ts`.
    private static func continues(_ walk: ArchiveManifest.Continuation, below bound: String?) -> Bool {
        !SlackDayFile.precedes(walk.top_ts, walk.below_ts)
            && (bound.map { SlackDayFile.precedes($0, walk.below_ts) } ?? true)
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
                        + "bookmark, so the next call reads those messages again and leaves their blocks as "
                        + "they are.")
        }
    }
}
