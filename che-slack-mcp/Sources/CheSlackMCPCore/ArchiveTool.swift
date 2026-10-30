import Foundation
import MCP
import SlackWebLib

/// `archive_conversation_to_markdown` (spec: slack-chat-archive; design:
/// 歸檔格式對齊 telegram-chat-archive, 第一版不下載檔案). Arguments are
/// checked first, so a refused argument reads no Keychain item, calls no
/// Slack method and writes no file.
extension SlackToolHandler {
    /// Top-level messages requested per `conversations.history` page: the
    /// most Slack recommends (design: 參數上限與來源).
    static let archivePageSize = historyLimit.range.upperBound
    /// History pages read at most per call (10000 top-level messages at
    /// `archivePageSize`), so one call has a bounded cost; about 18 s of
    /// history requests at the default 350 ms pacing, plus one replies
    /// request per thread parent. Our own choice, without a measurement
    /// behind it; `complete` is false when it stopped the walk, and the
    /// manifest records where the next call continues.
    static let archiveHistoryMaxPages = 50

    static let archiveTools: [Tool] = [
        tool("archive_conversation_to_markdown",
             description: """
             Write a conversation into markdown files, one per local day: \
             <output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md. Each file starts with YAML frontmatter \
             (team_id, conversation_id, date, utc_offset) and holds one block per message: <!-- msg:<ts> -->, a \
             header **HH:mm sender**： (a thread reply adds ↳ thread:<parent_ts>), and the text with Slack markup \
             turned into markdown. The sender is 我 for your own messages, else the user's display name, \
             Bot <bot_id> or User <user_id>. Replies of the thread parents written in this call are fetched and \
             written in the file of their own day. Attached files are written as [file: name](permalink) and never \
             downloaded. A day file that already exists is merged by ts: its blocks are kept, and a message \
             archived again replaces its own block. Directories are created owner-only (0700), day files 0600. \
             A manifest.json next to the day files records the newest top-level ts archived, the newest reply ts \
             of each thread parent inside the lookback window, the time of the last run and its counts, never \
             message text or names. Without after_ts or since_date only messages newer than the manifest's newest \
             ts are written (the whole history when there is no manifest), and the thread parents archived in the \
             last thread_lookback_days days are listed again so that a parent whose latest reply is newer than \
             the recorded one gets its replies fetched, starting after that reply; older threads are not \
             checked. A manifest that cannot be read or was not written for this conversation refuses the call; \
             move it aside to start over. At most \(archiveHistoryMaxPages) pages of \(archivePageSize) top-level \
             messages, and \(SlackWebClient.repliesMaxPages) pages of \(SlackWebClient.repliesPageSize) replies per \
             thread, are read per call; complete is false when messages were left out, so call again until it is \
             true. A walk stopped before the manifest's newest ts (or the oldest message, on a first archive) is \
             recorded in the manifest as a continuation: the next call without after_ts or since_date first \
             continues it below the oldest message it wrote, and the newest ts moves, to the top of that walk, \
             only once it gets there; messages newer than that are read by the call after. A thread cut the same \
             way continues after its newest reply recorded. after_ts and since_date read their own range: they do \
             not continue or change a recorded continuation, and while one is recorded they do not move the \
             newest ts. One archive of a conversation into an output_dir runs at a time, across server processes \
             too: a call made while another runs is an error and writes nothing. When Slack keeps rate limiting \
             after the client's retries, the call stops early and is not an error: the day files written so far \
             stay, the manifest's newest ts does not move but the point to continue below is recorded, and the \
             result has complete false, stopped_reason rate_limited, retry_after_seconds and a note; calling again \
             later continues there and merges the blocks already written in place. Any other Slack error is an \
             error result; the pages merged before it stay written and the manifest is left as it was. Returns \
             the day files changed (relative to output_dir) and message counts, never message text.
             """,
             properties: workspaceProperty.merging([
                 "conversation_id": prop("string", "The conversation's id, such as C0123ABCD, from list_conversations."),
                 "output_dir": prop("string", """
                     Absolute path of the directory to write under, created owner-only when missing. A relative path \
                     or ~ is refused.
                     """),
                 "after_ts": prop("string", """
                     Only messages after this Slack timestamp, written as a string such as "1730000000.000100". \
                     Takes precedence over since_date.
                     """),
                 "since_date": prop("string", """
                     Only messages from this local date on, written YYYY-MM-DD; the day starts at midnight at \
                     utc_offset.
                     """),
                 "utc_offset": prop("string", """
                     The offset for the files' dates and times: +HH:MM or -HH:MM, at most 18:00 either way, such as \
                     "+08:00". Defaults to the server's offset at the time of the call. Day files already written \
                     with another offset are not merged into: the call is refused.
                     """),
                 "thread_lookback_days": integerProp(threadLookbackDays, """
                     How many days back thread parents are checked again for new replies.
                     """),
             ]) { $1 },
             required: ["conversation_id", "output_dir"]),
    ]

    func archiveConversation(_ arguments: [String: Value]) async -> CallTool.Result {
        let localOffset = localOffsetSeconds()
        let start = now()
        return await checked(arguments, { args throws(ToolFailure) in
            try Self.archiveRequest(args, localOffsetSeconds: localOffset)
        }) { request, selection in
            let archiver = ConversationArchiver(client: client, selection: selection, request: request,
                                                maxPages: Self.archiveHistoryMaxPages, now: start)
            return ToolResult.json(try await archiver.run())
        }
    }
}

/// One archive call: takes the conversation's `ArchiveLock`, reads the
/// manifest, then the history newest first by cursor within
/// `ArchiveScope`, the replies of each thread parent written and of each
/// parent in the lookback window with a newer reply, the names of senders
/// and mentioned users (`users.info`, once per user per call); merges each
/// page into the day files before reading the next, and replaces the
/// manifest last. A walk stopped before its lower bound, by the page limit
/// or a rate limit, is recorded as the manifest's `continuation`, so the
/// next call continues below the oldest message written instead of reading
/// the same newest pages again (spec: "Incremental archive and manifest").
/// An error leaves the previous manifest, and the next call reads the same
/// messages again and merges them in place.
struct ConversationArchiver {
    let client: SlackWebClient
    let selection: ResolvedWorkspace
    let request: ArchiveRequest
    let maxPages: Int
    /// The start of the call: the end of the lookback window, and the run
    /// time the manifest records.
    let now: Date

    /// The result: paths and counts, never message text, sender names or
    /// file names.
    struct Summary: Encodable, Equatable {
        let team_id: String
        let conversation_id: String
        let utc_offset: String
        /// Day files whose content changed, relative to `output_dir`.
        var files: [String] = []
        var top_level_messages = 0
        var thread_replies = 0
        /// Messages that had no block in their day file before.
        var new_messages = 0
        /// Messages not written because their ts is not a Slack timestamp.
        var skipped_messages = 0
        /// False when the page limit or a rate limit stopped the history
        /// walk, a thread had more replies than one walk reads, or the call
        /// finished an unfinished walk and so did not look for messages
        /// newer than it.
        var complete = true
        /// Why the run stopped early; absent when it did not.
        enum StopReason: String, Encodable {
            /// Slack kept rate limiting after the client's retries.
            case rate_limited
        }

        var stopped_reason: StopReason?
        /// With `stopped_reason`: the wait Slack last asked for.
        var retry_after_seconds: Int?
        /// With `stopped_reason`: how many messages were written and how
        /// to resume.
        var note: String?

        mutating func stopRateLimited(retryAfterSeconds seconds: Int) {
            complete = false
            stopped_reason = .rate_limited
            retry_after_seconds = seconds
            let written = top_level_messages + thread_replies
            note = "Slack kept rate limiting this workspace after the client's retries, so the run stopped early "
                + "with \(written == 1 ? "1 message" : "\(written) messages") written. The manifest's newest ts did "
                + "not move: calling the tool again, after retry_after_seconds, continues below the oldest top-level "
                + "message this walk wrote, or reads the range again when it wrote none, and merges the blocks "
                + "already written in place."
        }
    }

    private var credential: SlackCredential { selection.credential }

    /// What one run carries from page to page.
    private struct Progress {
        var summary: Summary
        var changed: Set<String> = []
        var names = DirectMessageNames(limit: .max)
        var seen: Set<String> = []
        /// Per thread parent, the newest reply ts archived.
        var replyBookmarks: [String: String]
        /// The newest and oldest top-level ts this walk wrote, counting a
        /// message only once its page was written and, for a thread
        /// parent, its replies were read, so that a walk stopped part way
        /// continues at a message whose thread is complete.
        var walkNewest: String?
        var walkOldest: String?
        /// Slack lists newest first, so a listed message that is not
        /// written (below the bound) means every newer one was listed.
        var reachedBound = false

        mutating func wrote(_ topLevel: [String]) {
            for ts in topLevel {
                walkNewest = ArchiveScope.newer(walkNewest, ts)
                walkOldest = ArchiveScope.older(walkOldest, ts)
            }
        }
    }

    func run() async throws -> Summary {
        let directory = try ArchiveDirectory(outputDir: request.outputDir, teamID: selection.workspace.teamID,
                                             conversationID: request.conversationID)
        // Refusals that need no lock come first, so they create nothing.
        try directory.preflight(utcOffset: request.utcOffset)
        return try await ArchiveLock.holding(directory) { try await run(in: directory) }
    }

    /// The run, with the conversation's archive lock held. A rate limit
    /// the client gave up on stops it with a result that is not an error
    /// (spec: "Archive concurrency and partial progress"); every page
    /// merged before stays written, and:
    /// - `newest_ts` does not move, because Slack lists newest first and
    ///   the unread range below the written messages would be skipped;
    /// - the manifest records the continuation below the oldest top-level
    ///   message written, and is written only when that moved, so a stop
    ///   that wrote nothing to continue from leaves it byte-identical;
    /// - reply bookmarks are not moved, even for a thread written whole
    ///   before the stop: the next run fetches it again and merges it in
    ///   place, at the cost of a request, rather than trust a run that
    ///   stopped part way;
    /// - `last_run` describes this run when the manifest is written.
    /// Any other error is thrown on, with the same files kept and the
    /// manifest, its continuation included, left as it was.
    private func run(in directory: ArchiveDirectory) async throws -> Summary {
        // Again under the lock: a run that ended meanwhile may have written
        // day files at another offset.
        try directory.preflight(utcOffset: request.utcOffset)
        let previous = try directory.readManifest()
        let scope = ArchiveScope(request: request, bookmark: previous?.newest_ts,
                                 continuation: previous?.continuation, now: now)
        var progress = Progress(summary: Summary(team_id: directory.teamID, conversation_id: request.conversationID,
                                                 utc_offset: request.utcOffset),
                                replyBookmarks: previous?.newest_reply_ts ?? [:])
        do {
            try await walk(scope, into: directory, progress: &progress)
        } catch SlackError.rateLimited(let seconds) {
            progress.summary.files = progress.changed.sorted()
            progress.summary.stopRateLimited(retryAfterSeconds: seconds)
            let continuation = continuation(scope: scope, progress: progress, previous: previous, stopped: true)
            if continuation != previous?.continuation {
                try directory.writeManifest(ArchiveManifest(
                    teamID: directory.teamID, conversationID: request.conversationID, newestTS: scope.bookmark,
                    newestReplyTS: previous?.newest_reply_ts ?? [:], continuation: continuation,
                    lastRun: lastRun(progress.summary)))
            }
            return progress.summary
        }
        // A finished continuation looked for nothing newer than its top.
        if scope.continuation != nil, progress.reachedBound { progress.summary.complete = false }
        progress.summary.files = progress.changed.sorted()
        try directory.writeManifest(manifest(scope: scope, progress: progress, previous: previous))
        return progress.summary
    }

    /// Reads the history newest first by cursor within `scope`, and merges
    /// each page into the day files before reading the next. A rate limit
    /// on a thread's replies ends the page there: the messages listed
    /// before it, that parent included, are still written (their names
    /// looked up, `users.info` being limited apart), then the rate limit is
    /// thrown on. A page whose name lookup is rate limited is not written:
    /// a message is written only with its sender's name. A continued walk
    /// lists only below the continuation's `below_ts`.
    private func walk(_ scope: ArchiveScope, into directory: ArchiveDirectory,
                      progress: inout Progress) async throws {
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await client.conversationHistory(channel: request.conversationID,
                                                            limit: SlackToolHandler.archivePageSize,
                                                            oldest: scope.listOldest, latest: scope.listLatest,
                                                            cursor: cursor, credential: credential)
            pages += 1
            var batch: [SlackMessage] = []
            /// The top-level ts of `batch` whose replies, if asked for,
            /// were read; not the parent whose replies were rate limited.
            var topLevel: [String] = []
            var stop: SlackError?
            messages: for message in page.messages {
                guard SlackDayFile.seconds(ofTS: message.ts) != nil else {
                    progress.summary.skipped_messages += 1
                    continue
                }
                guard progress.seen.insert(message.ts).inserted else { continue }
                let isNew = scope.isWritten(message.ts)
                if isNew { batch.append(message) } else { progress.reachedBound = true }
                if isNew ? ArchiveScope.isThreadParent(message)
                    : scope.needsReplies(message, recorded: progress.replyBookmarks[message.ts]) {
                    do {
                        batch += try await replies(of: message, progress: &progress)
                    } catch SlackError.rateLimited(let seconds) {
                        stop = .rateLimited(retryAfterSeconds: seconds)
                        break messages
                    }
                }
                if isNew { topLevel.append(message.ts) }
            }
            try await write(batch, into: directory, names: &progress.names, summary: &progress.summary,
                            changed: &progress.changed)
            progress.wrote(topLevel)
            if let stop { throw stop }
            cursor = page.nextCursor
        } while cursor != nil && pages < maxPages
        if cursor == nil { progress.reachedBound = true } else { progress.summary.complete = false }
    }

    /// The replies of `parent` not yet seen in this run, oldest first;
    /// only those after the reply bookmark when one is recorded (spec:
    /// "Thread replies and lookback"), the parent Slack still returns
    /// first being left out. The bookmark becomes the newest reply Slack
    /// returned (all of them are written now or were before). A thread
    /// longer than one walk leaves `complete` false; its bookmark is then
    /// the newest reply read, so the next run continues after it.
    private func replies(of parent: SlackMessage, progress: inout Progress) async throws -> [SlackMessage] {
        let thread = try await client.conversationReplies(channel: request.conversationID, ts: parent.ts,
                                                          oldest: progress.replyBookmarks[parent.ts],
                                                          credential: credential)
        if thread.hasMore { progress.summary.complete = false }
        var replies: [SlackMessage] = []
        for reply in thread.messages where reply.ts != parent.ts {
            guard SlackDayFile.seconds(ofTS: reply.ts) != nil else {
                progress.summary.skipped_messages += 1
                continue
            }
            progress.replyBookmarks[parent.ts] = ArchiveScope.newer(progress.replyBookmarks[parent.ts], reply.ts)
            if progress.seen.insert(reply.ts).inserted { replies.append(reply) }
        }
        return replies
    }

    /// The manifest after a run that was not stopped. `newest_ts` moves
    /// only when the walk reached its bound, to the newest message of the
    /// whole walk (a continued one included): a walk the page limit stopped
    /// above it left a gap below the messages it wrote, which a moved
    /// bookmark would skip for good; that gap is the continuation instead.
    /// Chosen: with `after_ts` or `since_date` and a continuation pending,
    /// `newest_ts` stays, because it is the lower bound the continuation
    /// still has to reach. Reply bookmarks are kept only for parents inside
    /// this run's window; a parent that left it is dropped, and a later run
    /// with a wider window has no record of it, so its replies are fetched
    /// once more and merged in place.
    private func manifest(scope: ArchiveScope, progress: Progress, previous: ArchiveManifest?) -> ArchiveManifest {
        let keepsBound = request.oldest != nil && previous?.continuation != nil
        let walkTop = ArchiveScope.newer(scope.continuation?.top_ts, progress.walkNewest)
        return ArchiveManifest(
            teamID: progress.summary.team_id, conversationID: progress.summary.conversation_id,
            newestTS: progress.reachedBound && !keepsBound ? ArchiveScope.newer(scope.bookmark, walkTop)
                : scope.bookmark,
            newestReplyTS: progress.replyBookmarks.filter { scope.isInWindow($0.key) },
            continuation: continuation(scope: scope, progress: progress, previous: previous,
                                       stopped: !progress.reachedBound),
            lastRun: lastRun(progress.summary))
    }

    /// The unfinished walk the manifest records after this run, or nil.
    /// Chosen: `after_ts` and `since_date` keep the previous one as it is,
    /// and record none of their own (their range is the caller's, not the
    /// manifest's). Otherwise a walk that reached its bound leaves none; a
    /// stopped one keeps the top of the walk it continued, or its own
    /// newest message, and continues below the oldest message written; a
    /// stopped walk that wrote nothing keeps what was recorded.
    private func continuation(scope: ArchiveScope, progress: Progress, previous: ArchiveManifest?,
                              stopped: Bool) -> ArchiveManifest.Continuation? {
        guard request.oldest == nil else { return previous?.continuation }
        guard stopped else { return nil }
        guard let top = scope.continuation?.top_ts ?? progress.walkNewest,
              let below = ArchiveScope.older(scope.continuation?.below_ts, progress.walkOldest)
        else { return scope.continuation }
        return .init(top_ts: top, below_ts: below)
    }

    private func lastRun(_ summary: Summary) -> ArchiveManifest.LastRun {
        .init(at: ArchiveManifest.timestamp(now, offsetSeconds: request.offsetSeconds),
              top_level_messages: summary.top_level_messages, thread_replies: summary.thread_replies,
              new_messages: summary.new_messages)
    }

    private func write(_ batch: [SlackMessage], into directory: ArchiveDirectory, names: inout DirectMessageNames,
                       summary: inout Summary, changed: inout Set<String>) async throws {
        guard !batch.isEmpty else { return }
        let known = try await resolveNames(batch, names: &names)
        let archived = batch.map { message in
            ArchivedMessage(ts: message.ts, parentTS: parentTS(message), sender: sender(message, known),
                            body: SlackMarkup.body(text: message.text, files: message.files ?? [],
                                                   userName: { known[$0] }))
        }
        try directory.createDirectories()
        let days = SlackDayFile.byDay(archived, offsetSeconds: request.offsetSeconds)
        for day in days.keys.sorted() {
            let (didChange, added) = try directory.write(day: day, messages: days[day] ?? [],
                                                         utcOffset: request.utcOffset)
            summary.new_messages += added.count
            if didChange { changed.insert(directory.relativePath(day: day)) }
        }
        let replies = archived.filter { $0.parentTS != nil }.count
        summary.thread_replies += replies
        summary.top_level_messages += archived.count - replies
    }

    /// Names for the senders (other than the user) and the mentioned users
    /// of `batch`. A user Slack does not know has no name; any other
    /// failure stops the call.
    private func resolveNames(_ batch: [SlackMessage],
                              names: inout DirectMessageNames) async throws -> [String: String] {
        var users: [String] = []
        for message in batch {
            if let user = message.user, user != selection.workspace.userID { users.append(user) }
            users += SlackMarkup.mentionedUsers(message.text ?? "")
        }
        var known: [String: String] = [:]
        for user in users where known[user] == nil && ToolArguments.isSlackID(user) {
            let name = try await names.name(of: user) {
                try await client.userInfo(user: user, credential: credential)
            }
            known[user] = name.value
        }
        return known
    }

    /// The parent of a thread reply; a malformed `thread_ts` is not written
    /// into a header, so the message is written as top-level.
    private func parentTS(_ message: SlackMessage) -> String? {
        guard let parent = message.threadTS, parent != message.ts, SlackDayFile.seconds(ofTS: parent) != nil
        else { return nil }
        return parent
    }

    /// spec: `我` for the user's own messages, the display name when known,
    /// `Bot <bot_id>` for a bot message, `User <user_id>` otherwise. Spec
    /// silent, chosen: `Unknown` for a message with neither.
    private func sender(_ message: SlackMessage, _ known: [String: String]) -> String {
        if let user = message.user, user == selection.workspace.userID { return "我" }
        if let user = message.user, let name = known[user] { return name }
        if let bot = message.botID, !bot.isEmpty { return "Bot \(bot)" }
        if let user = message.user, !user.isEmpty { return "User \(user)" }
        return "Unknown"
    }
}
