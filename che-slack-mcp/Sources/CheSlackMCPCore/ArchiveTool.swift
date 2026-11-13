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
    /// `archivePageSize`): about 18 s of history requests at the default
    /// 350 ms pacing. Only history pages count. The `conversations.replies`
    /// requests (up to `SlackWebClient.repliesMaxPages` per thread parent
    /// fetched) and the `users.info` name lookups come on top, with no limit
    /// per call, so this alone does not bound the cost of a call (#104). Our
    /// own choice, without a measurement behind it; `complete` is false when
    /// it stopped the walk above its lower bound, and the manifest records
    /// where the next call continues; when it stopped only the listing of
    /// the lookback window, `lookback_complete` is false instead.
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
             downloaded. A day file that already exists is merged by ts: its blocks are kept as they are, a \
             message archived again keeps the block archived first (an edited message its archived text, a \
             renamed sender the archived name), and only a message not yet in the file is inserted, in ts \
             order; a file with nothing new is left byte-identical. Directories are created owner-only (0700), \
             day files 0600. \
             A manifest.json next to the day files records the newest top-level ts archived, the newest reply ts \
             of each thread parent inside the lookback window or not yet read to its end, the time of the last run \
             and its counts, never message text or names. Without after_ts or since_date only messages newer than \
             the manifest's newest \
             ts are written (the whole history when there is no manifest), and the thread parents archived in the \
             last thread_lookback_days days are listed again so that a parent whose latest reply is newer than \
             the recorded one gets its replies fetched, starting after that reply; older threads are not \
             checked, nor is a parent listed there whose block is not in its day file (one an earlier call with \
             since_date or after_ts started after), so the lookback fetches no replies of a parent missing from the \
             archive; a reply also sent to the conversation is archived with its top-level messages. A manifest that \
             cannot be read or was not written for this conversation refuses the call; move it aside to start \
             over. At most \(archiveHistoryMaxPages) pages of \(archivePageSize) top-level \
             messages, and \(SlackWebClient.repliesMaxPages) pages of \(SlackWebClient.repliesPageSize) replies per \
             thread, are read per call; complete is false when messages were left out, by these limits or because \
             Slack said it had more without giving a cursor to read them, so call again until it is true. Listing \
             the lookback window counts in the same page limit but does not by itself make complete \
             false: every result has lookback_complete, false when the call did not list down to the start of the \
             window, and when complete is true a note then says that the thread parents in the rest of the window \
             were not checked for new replies and that a smaller thread_lookback_days lists fewer messages. A \
             walk stopped before the manifest's newest ts (or the oldest message, on a first archive) is \
             recorded in the manifest as a continuation: the next call without after_ts or since_date first \
             continues it below the oldest message it wrote, and the newest ts moves, to the top of that walk, \
             only once it gets there; messages newer than that are read by the call after. A thread cut the same \
             way is recorded too, and every later call continues it after its newest reply recorded, also when its \
             parent is older than the lookback window. after_ts and since_date read their own range, from the newest \
             message down to that bound, and do not continue or change the continuation above. They move the newest \
             ts only when their bound is at or before it, once their walk gets there, and not while a continuation \
             is recorded. A range stopped before its bound is recorded in the manifest with that bound, replacing a \
             range recorded with another; the next call with the same after_ts or since_date continues it below the \
             oldest message it wrote, the call after reads only messages newer than the newest it wrote, and once \
             that one gets there the range is dropped. Calls without after_ts and since_date, or with another bound \
             whose walk gets to it, leave a recorded range as it is. One archive of a conversation into an \
             output_dir runs at a time, across server processes \
             too: a call made while another runs is an error and writes nothing. When Slack keeps rate limiting \
             after the client's retries, the call stops early and is not an error: the day files written so far \
             stay, the manifest's newest ts does not move, the point to continue below is recorded when the walk \
             stopped above its lower bound, a thread cut short in this call is recorded with the newest reply \
             written (other reply records do not move), and the result has complete false, stopped_reason \
             rate_limited, retry_after_seconds and a note; calling again later continues from there, or reads the \
             same range again when nothing was recorded, and keeps the blocks already written as they are. Any \
             other Slack error is an error result; the pages merged before it stay written and the manifest is left as \
             it was. Returns the day files changed (relative to output_dir) and message counts, never message text.
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
                                                maxPages: archiveMaxPages, now: start)
            return ToolResult.json(try await archiver.run())
        }
    }
}

/// One archive call: takes the conversation's `ArchiveLock`, reads the
/// manifest, then the history newest first by cursor within
/// `ArchiveScope`, the replies of each thread parent written and of each
/// parent in the lookback window with a newer reply whose block is in its
/// day file, then the replies of
/// each thread the manifest lists as unfinished that the walk did not
/// fetch, and the names of senders and mentioned users (`users.info`, once
/// per user per call); merges each page and each such thread into the day
/// files before reading the next, and replaces the manifest last. A walk
/// stopped before its lower bound, by the page limit or a rate limit, is
/// recorded as the manifest's `continuation` (its `range`, with
/// `after_ts` or `since_date`), so the next such call continues below the
/// oldest message written instead of reading the same newest pages again
/// (spec: "Incremental archive and manifest"). An error leaves the
/// previous manifest, and the next call reads the same messages again,
/// inserting only those not yet in the day files.
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
        /// Day files created or with a message inserted, relative to
        /// `output_dir`; a file whose messages all had blocks is unchanged
        /// and not listed.
        var files: [String] = []
        /// Top-level messages and thread replies this call archived: merged
        /// into their day files, one whose block was already there and was
        /// left as it was included.
        var top_level_messages = 0
        var thread_replies = 0
        /// Messages that had no block in their day file before: the ones
        /// this call wrote.
        var new_messages = 0
        /// Messages not written because their ts is not a Slack timestamp.
        var skipped_messages = 0
        /// False when the page limit, or Slack's `has_more` without a next
        /// cursor, stopped the history walk above its lower bound, a rate
        /// limit stopped the call, a thread had more replies than one walk
        /// reads or Slack said so without a cursor (and so is still
        /// unfinished), or the call finished an unfinished walk or range and
        /// so did not look for messages newer than it. A walk that wrote
        /// every message above its bound and was then stopped by the page
        /// limit while listing the lookback window leaves it true (spec:
        /// "Incremental archive and manifest"); `lookback_complete` tells.
        var complete = true
        /// True when the walk listed everything down to the start of the
        /// lookback window, or down to its lower bound when the window
        /// starts later or is 0 days; false when the page limit or Slack's
        /// `has_more` without a next cursor stopped it first, above its
        /// bound or inside the window, or a rate limit stopped it.
        var lookback_complete = false
        /// Why the run stopped early; absent when it did not.
        enum StopReason: String, Encodable {
            /// Slack kept rate limiting after the client's retries.
            case rate_limited
        }

        var stopped_reason: StopReason?
        /// With `stopped_reason`: the wait Slack last asked for.
        var retry_after_seconds: Int?
        /// With `stopped_reason`: how many messages were written and how
        /// to resume. On a complete run whose `lookback_complete` is false:
        /// that the thread parents in the rest of the window were not
        /// checked, and that a smaller `thread_lookback_days` lists fewer
        /// messages. Absent otherwise.
        var note: String?

        mutating func stopRateLimited(retryAfterSeconds seconds: Int) {
            complete = false
            stopped_reason = .rate_limited
            retry_after_seconds = seconds
            let written = new_messages
            note = "Slack kept rate limiting this workspace after the client's retries, so the run stopped early "
                + "with \(written == 1 ? "1 message" : "\(written) messages") written. The manifest's newest ts did "
                + "not move: calling the tool again, after retry_after_seconds, continues where the manifest records "
                + "this walk stopped, or reads the same range again when nothing was recorded, and leaves the blocks "
                + "already written as they are."
        }

        /// The note of a complete run whose walk the page limit stopped
        /// inside the lookback window; nothing for any other run.
        mutating func noteUnlistedWindow() {
            guard complete, !lookback_complete else { return }
            note = "All new messages were written, but the page limit stopped this call before it had listed the "
                + "whole lookback window, so the thread parents in the rest of the window were not checked for new "
                + "replies. A smaller thread_lookback_days lists fewer messages."
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
        /// Parents whose replies this run fetched.
        var fetched: Set<String> = []
        /// Parents whose replies the reply page limit cut: the manifest's
        /// list, plus the threads cut in this run, less those finished.
        var unfinished: Set<String>
        /// Threads cut in this run whose replies are read but not yet
        /// written, with the newest reply read.
        var cutPending: [String: String] = [:]
        /// Threads cut in this run whose replies were written into the day
        /// files, with the newest reply written: what a stopped run records.
        var cutWritten: [String: String] = [:]
        /// Per day, the ts of the blocks in its file, read once per run when
        /// a parent listed for the lookback window is checked, and kept
        /// current as the run writes that day.
        var dayAnchors: [String: Set<String>] = [:]

        /// Records a batch merged into the day files: its top-level ts, and
        /// the cut threads whose replies it held.
        mutating func wrote(_ topLevel: [String]) {
            for ts in topLevel {
                walkNewest = ArchiveScope.newer(walkNewest, ts)
                walkOldest = ArchiveScope.older(walkOldest, ts)
            }
            cutWritten.merge(cutPending) { $1 }
            cutPending = [:]
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
    /// - the manifest records the continuation (or the range's) below the
    ///   oldest top-level message written, and is written only when one of
    ///   them or a cut thread's record moved, so a stop that wrote nothing
    ///   to continue from leaves it byte-identical;
    /// - reply bookmarks and the unfinished threads are not moved, even for
    ///   a thread written whole before the stop: the next run fetches it
    ///   again, writing only the replies not yet in the day files, at the
    ///   cost of a request, rather than trust a run that stopped part way. The exception is a thread cut
    ///   short in this run whose replies were written before the stop: it
    ///   is listed as unfinished with the newest reply written (spec:
    ///   "Thread replies and lookback"), because the walk continues below
    ///   the oldest message written, so a cut parent above that is not
    ///   listed again and nothing else would bring the rest of its replies
    ///   back;
    /// - `last_run` describes this run when the manifest is written.
    /// Any other error is thrown on, with the same files kept and the
    /// manifest, its continuation and range included, left as it was.
    private func run(in directory: ArchiveDirectory) async throws -> Summary {
        // Again under the lock: a run that ended meanwhile may have written
        // day files at another offset.
        try directory.preflight(utcOffset: request.utcOffset)
        let previous = try directory.readManifest()
        let scope = ArchiveScope(request: request, manifest: previous, now: now)
        var progress = Progress(summary: Summary(team_id: directory.teamID, conversation_id: request.conversationID,
                                                 utc_offset: request.utcOffset),
                                replyBookmarks: previous?.newest_reply_ts ?? [:],
                                unfinished: Set(previous?.unfinished_threads ?? []))
        do {
            try await walk(scope, into: directory, progress: &progress)
            try await continueThreads(previous?.unfinished_threads ?? [], into: directory, progress: &progress)
        } catch SlackError.rateLimited(let seconds) {
            progress.summary.files = progress.changed.sorted()
            progress.summary.stopRateLimited(retryAfterSeconds: seconds)
            if let manifest = stoppedManifest(scope: scope, progress: progress, previous: previous) {
                try directory.writeManifest(manifest)
            }
            return progress.summary
        }
        // A finished continuation looked for nothing newer than its top.
        if scope.continuation != nil, progress.reachedBound { progress.summary.complete = false }
        if !progress.unfinished.isEmpty { progress.summary.complete = false }
        progress.summary.noteUnlistedWindow()
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
    /// lists only below the continuation's `below_ts`. The page limit makes
    /// the call incomplete only when it stops the walk above its bound;
    /// stopping it inside the lookback window leaves `lookback_complete`
    /// false and nothing else. Slack's `has_more` without a next cursor
    /// stops the walk the same way (spec: "Incremental archive and
    /// manifest"): the walk cannot list what Slack left out, so it has not
    /// reached its bound unless it already listed a message below it.
    private func walk(_ scope: ArchiveScope, into directory: ArchiveDirectory,
                      progress: inout Progress) async throws {
        var cursor: String?
        var pages = 0
        /// Whether Slack has messages the walk did not list: a next cursor,
        /// or `has_more` without one.
        var more = false
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
                if try isNew ? ArchiveScope.isThreadParent(message)
                    : needsReplies(message, scope: scope, in: directory, progress: &progress) {
                    do {
                        batch += try await replies(of: message.ts, progress: &progress)
                    } catch SlackError.rateLimited(let seconds) {
                        stop = .rateLimited(retryAfterSeconds: seconds)
                        break messages
                    }
                }
                if isNew { topLevel.append(message.ts) }
            }
            try await write(batch, into: directory, progress: &progress)
            progress.wrote(topLevel)
            if let stop { throw stop }
            cursor = page.nextCursor
            more = cursor != nil || page.hasMore
        } while cursor != nil && pages < maxPages
        if !more {
            progress.reachedBound = true
            progress.summary.lookback_complete = true
        } else if !progress.reachedBound {
            progress.summary.complete = false
        }
    }

    /// The replies of the thread `parent` not yet seen in this run, oldest
    /// first; only those after the reply bookmark when one is recorded
    /// (spec: "Thread replies and lookback"), the parent Slack still
    /// returns first being left out. The bookmark becomes the newest reply
    /// Slack returned (all of them are written now or were before). A
    /// thread longer than one walk, or one whose replies Slack says have
    /// more without a cursor to follow, leaves `complete` false and is
    /// listed as unfinished; its bookmark is then the newest reply read, so
    /// the next run continues after it, and it waits in `cutPending` until
    /// its replies are written. A thread read to its end leaves the list.
    private func replies(of parent: String, progress: inout Progress) async throws -> [SlackMessage] {
        let thread = try await client.conversationReplies(channel: request.conversationID, ts: parent,
                                                          oldest: progress.replyBookmarks[parent],
                                                          credential: credential)
        progress.fetched.insert(parent)
        if thread.hasMore {
            progress.summary.complete = false
            progress.unfinished.insert(parent)
        } else {
            progress.unfinished.remove(parent)
        }
        var replies: [SlackMessage] = []
        for reply in thread.messages where reply.ts != parent {
            guard SlackDayFile.seconds(ofTS: reply.ts) != nil else {
                progress.summary.skipped_messages += 1
                continue
            }
            progress.replyBookmarks[parent] = ArchiveScope.newer(progress.replyBookmarks[parent], reply.ts)
            if progress.seen.insert(reply.ts).inserted { replies.append(reply) }
        }
        if thread.hasMore { progress.cutPending[parent] = progress.replyBookmarks[parent] }
        return replies
    }

    /// Continues each thread in `parents` (the manifest's unfinished
    /// threads, oldest first) that the walk did not fetch, whatever the
    /// parent's age and the lookback window (spec: "Thread replies and
    /// lookback"): its replies after its bookmark are written into the day
    /// files of their own days, one thread at a time; the parent is not
    /// written again. A rate limit is thrown on, as in the walk. Spec
    /// silent, chosen: a thread Slack answers `thread_not_found` for (its
    /// parent deleted, or removed by a retention policy) has no replies
    /// left to write, so it leaves the list instead of failing every later
    /// call.
    private func continueThreads(_ parents: [String], into directory: ArchiveDirectory,
                                 progress: inout Progress) async throws {
        for parent in parents where !progress.fetched.contains(parent) {
            let replies: [SlackMessage]
            do {
                replies = try await self.replies(of: parent, progress: &progress)
            } catch SlackError.slackError(let code) where code == "thread_not_found" {
                progress.unfinished.remove(parent)
                continue
            }
            try await write(replies, into: directory, progress: &progress)
            progress.wrote([])
        }
    }

    /// Whether a thread parent listed but not written gets its replies
    /// fetched (spec: "Thread replies and lookback"): `scope.needsReplies`
    /// accepts it, and its block is already in its day file, or the
    /// manifest lists its thread as unfinished. A parent at or below the
    /// bookmark was not necessarily archived: an earlier call with
    /// `since_date` or `after_ts` may have started after it, and its
    /// replies would be written without their parent.
    private func needsReplies(_ message: SlackMessage, scope: ArchiveScope, in directory: ArchiveDirectory,
                              progress: inout Progress) throws -> Bool {
        guard scope.needsReplies(message, recorded: progress.replyBookmarks[message.ts]) else { return false }
        if progress.unfinished.contains(message.ts) { return true }
        let day = SlackDayFile.dayKey(ts: message.ts, offsetSeconds: request.offsetSeconds)
        if let anchors = progress.dayAnchors[day] { return anchors.contains(message.ts) }
        let anchors = try directory.archivedTS(day: day, utcOffset: request.utcOffset)
        progress.dayAnchors[day] = anchors
        return anchors.contains(message.ts)
    }

    /// The manifest after a run that was not stopped. Reply bookmarks are
    /// kept for parents inside this run's window and for unfinished
    /// threads, whatever their age; any other parent is dropped, and a
    /// later run with a wider window has no record of it, so its replies
    /// are fetched once more and only those not yet in the day files are
    /// written.
    private func manifest(scope: ArchiveScope, progress: Progress, previous: ArchiveManifest?) -> ArchiveManifest {
        let unfinished = progress.unfinished
        return ArchiveManifest(
            teamID: progress.summary.team_id, conversationID: progress.summary.conversation_id,
            newestTS: newestTS(scope: scope, progress: progress, previous: previous),
            newestReplyTS: progress.replyBookmarks.filter { scope.isInWindow($0.key) || unfinished.contains($0.key) },
            continuation: continuation(scope: scope, progress: progress, previous: previous,
                                       stopped: !progress.reachedBound),
            range: range(scope: scope, progress: progress, previous: previous, stopped: !progress.reachedBound),
            unfinishedThreads: unfinished.sorted(by: SlackDayFile.precedes),
            lastRun: lastRun(progress.summary))
    }

    /// The manifest after a run a rate limit stopped, or nil to leave the
    /// previous one byte-identical when nothing it records moved (see
    /// `run(in:)`): `newest_ts` stays; the continuation or range records
    /// where the walk stopped; reply bookmarks and unfinished threads stay
    /// as they were, plus the threads cut in this run whose replies were
    /// written, each with the newest reply written. A thread the manifest
    /// already lists keeps its old bookmark unless it is one of those.
    private func stoppedManifest(scope: ArchiveScope, progress: Progress,
                                 previous: ArchiveManifest?) -> ArchiveManifest? {
        let continuation = continuation(scope: scope, progress: progress, previous: previous, stopped: true)
        let range = range(scope: scope, progress: progress, previous: previous, stopped: true)
        let replyTS = previous?.newest_reply_ts ?? [:]
        let listed = previous?.unfinished_threads ?? []
        let cut = progress.cutWritten
        let unfinished = cut.isEmpty ? listed : Set(listed).union(cut.keys).sorted(by: SlackDayFile.precedes)
        let newReplyTS = replyTS.merging(cut) { $1 }
        guard continuation != previous?.continuation || range != previous?.range || unfinished != listed
                || newReplyTS != replyTS else { return nil }
        return ArchiveManifest(
            teamID: progress.summary.team_id, conversationID: progress.summary.conversation_id,
            newestTS: scope.bookmark, newestReplyTS: newReplyTS, continuation: continuation, range: range,
            unfinishedThreads: unfinished, lastRun: lastRun(progress.summary))
    }

    /// `newest_ts` after a run that was not stopped (spec: "Incremental
    /// archive and manifest"). It moves only when the walk reached its
    /// bound: a walk the page limit stopped above it left a gap below the
    /// messages it wrote, which a moved bookmark would skip for good; that
    /// gap is the continuation instead. Without `after_ts` and `since_date`
    /// it moves to the newest message of the whole walk, a continued one
    /// included. With them it moves only when their lower bound is at or
    /// before it (or there is none), so that every message between the two
    /// was read, and no default continuation is pending, because
    /// `newest_ts` is the lower bound that one still has to reach; it then
    /// moves to the newest message the range has written contiguously from
    /// its lower bound: that of the recorded range it continued, or of the
    /// walk it continued, or of this walk.
    private func newestTS(scope: ArchiveScope, progress: Progress, previous: ArchiveManifest?) -> String? {
        guard progress.reachedBound else { return scope.bookmark }
        let walkTop = ArchiveScope.newer(scope.continuation?.top_ts, progress.walkNewest)
        guard let lower = request.oldest else { return ArchiveScope.newer(scope.bookmark, walkTop) }
        guard previous?.continuation == nil, scope.bookmark.map({ !SlackDayFile.precedes($0, lower) }) ?? true
        else { return scope.bookmark }
        return ArchiveScope.newer(scope.bookmark, ArchiveScope.newer(scope.range?.newest_ts, walkTop))
    }

    /// The unfinished walk the manifest records after this run, or nil.
    /// `after_ts` and `since_date` keep the previous one as it is: their
    /// own walk is recorded in `range`. Otherwise a walk that reached its
    /// bound leaves none, and a stopped one is recorded by `stoppedWalk`.
    private func continuation(scope: ArchiveScope, progress: Progress, previous: ArchiveManifest?,
                              stopped: Bool) -> ArchiveManifest.Continuation? {
        guard request.oldest == nil else { return previous?.continuation }
        return stopped ? stoppedWalk(scope: scope, progress: progress) : nil
    }

    /// The explicit range the manifest records after this run, or nil
    /// (spec: "Incremental archive and manifest"):
    /// - without `after_ts` and `since_date`, the previous one as it is;
    /// - continuing the recorded range of the same lower bound: a stopped
    ///   walk is recorded by `stoppedWalk`, keeping the range's `newest_ts`;
    ///   a continued walk that reached the bound clears its continuation
    ///   and moves `newest_ts` to the continuation's top (nothing newer was
    ///   looked for, so the call is not complete); a walk from the top that
    ///   reached it means the range caught up, and drops the record;
    /// - with another lower bound, or none recorded: a walk stopped before
    ///   its bound after writing something is recorded as a new range,
    ///   replacing the previous one; otherwise the previous one stays. A
    ///   rate limit after the walk reached its bound does not replace it.
    private func range(scope: ArchiveScope, progress: Progress, previous: ArchiveManifest?,
                       stopped: Bool) -> ArchiveManifest.ExplicitRange? {
        guard let lower = request.oldest else { return previous?.range }
        guard let recorded = scope.range else {
            guard !progress.reachedBound, let walk = stoppedWalk(scope: scope, progress: progress)
            else { return previous?.range }
            return .init(oldest_ts: lower, newest_ts: nil, continuation: walk)
        }
        if stopped {
            return .init(oldest_ts: lower, newest_ts: recorded.newest_ts,
                         continuation: stoppedWalk(scope: scope, progress: progress))
        }
        guard let continued = recorded.continuation else { return nil }
        return .init(oldest_ts: lower,
                     newest_ts: ArchiveScope.newer(recorded.newest_ts,
                                                   ArchiveScope.newer(continued.top_ts, progress.walkNewest)),
                     continuation: nil)
    }

    /// Where a stopped walk continues: from the top of the walk it
    /// continued, or its own newest message, below the oldest message
    /// written. A stopped walk that wrote nothing keeps what was recorded.
    private func stoppedWalk(scope: ArchiveScope, progress: Progress) -> ArchiveManifest.Continuation? {
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

    /// Merges `batch` into the day files, names looked up first, and counts
    /// it in the summary; every message of the batch has a block afterwards,
    /// which `progress.dayAnchors` records for a day it holds.
    private func write(_ batch: [SlackMessage], into directory: ArchiveDirectory,
                       progress: inout Progress) async throws {
        guard !batch.isEmpty else { return }
        let known = try await resolveNames(batch, names: &progress.names)
        let archived = batch.map { message in
            ArchivedMessage(ts: message.ts, parentTS: parentTS(message), sender: sender(message, known),
                            body: SlackMarkup.body(text: message.text, files: message.files ?? [],
                                                   userName: { known[$0] }))
        }
        try directory.createDirectories()
        let days = SlackDayFile.byDay(archived, offsetSeconds: request.offsetSeconds)
        for day in days.keys.sorted() {
            let messages = days[day] ?? []
            let (didChange, added) = try directory.write(day: day, messages: messages, utcOffset: request.utcOffset)
            progress.summary.new_messages += added.count
            if didChange { progress.changed.insert(directory.relativePath(day: day)) }
            progress.dayAnchors[day]?.formUnion(messages.map(\.ts))
        }
        let replies = archived.filter { $0.parentTS != nil }.count
        progress.summary.thread_replies += replies
        progress.summary.top_level_messages += archived.count - replies
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
