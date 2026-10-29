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
    /// behind it; `complete` is false when it stopped the walk.
    static let archiveHistoryMaxPages = 50

    static let archiveTools: [Tool] = [
        tool("archive_conversation_to_markdown",
             description: """
             Write a conversation into markdown files, one per local day: \
             <output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md. Each file starts with YAML frontmatter \
             (team_id, conversation_id, date, utc_offset) and holds one block per message: <!-- msg:<ts> -->, a \
             header **HH:mm sender**： (a thread reply adds ↳ thread:<parent_ts>), and the text with Slack markup \
             turned into markdown. The sender is 我 for your own messages, else the user's display name, \
             Bot <bot_id> or User <user_id>. Replies of the thread parents read in this call are fetched and \
             written in the file of their own day. Attached files are written as [file: name](permalink) and never \
             downloaded. A day file that already exists is merged by ts: its blocks are kept, and a message \
             archived again replaces its own block. Directories are created owner-only (0700), day files 0600. \
             Without after_ts or since_date the whole history is read, at most \(archiveHistoryMaxPages) pages of \
             \(archivePageSize) top-level messages per call; complete is false when messages were left out. \
             Returns the day files changed (relative to output_dir) and message counts, never message text.
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
        return await checked(arguments, { args throws(ToolFailure) in
            try Self.archiveRequest(args, localOffsetSeconds: localOffset)
        }) { request, selection in
            let archiver = ConversationArchiver(client: client, selection: selection, request: request,
                                                maxPages: Self.archiveHistoryMaxPages)
            return ToolResult.json(try await archiver.run())
        }
    }
}

/// One archive call: reads the history newest first by cursor, the replies
/// of each thread parent read, the names of senders and mentioned users
/// (`users.info`, once per user per call), and merges each page into the
/// day files before reading the next.
struct ConversationArchiver {
    let client: SlackWebClient
    let selection: ResolvedWorkspace
    let request: ArchiveRequest
    let maxPages: Int

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
        /// False when the page limit stopped the history walk, or a thread
        /// had more replies than one walk reads.
        var complete = true
    }

    private var credential: SlackCredential { selection.credential }

    func run() async throws -> Summary {
        let directory = try ArchiveDirectory(outputDir: request.outputDir, teamID: selection.workspace.teamID,
                                             conversationID: request.conversationID)
        try directory.preflight(utcOffset: request.utcOffset)
        var summary = Summary(team_id: directory.teamID, conversation_id: request.conversationID,
                              utc_offset: request.utcOffset)
        var changed: Set<String> = []
        var names = DirectMessageNames(limit: .max)
        var seen: Set<String> = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await client.conversationHistory(channel: request.conversationID,
                                                            limit: SlackToolHandler.archivePageSize,
                                                            oldest: request.oldest, cursor: cursor,
                                                            credential: credential)
            pages += 1
            var batch: [SlackMessage] = []
            for message in page.messages {
                guard SlackDayFile.seconds(ofTS: message.ts) != nil else { summary.skipped_messages += 1; continue }
                guard isInRange(message.ts), seen.insert(message.ts).inserted else { continue }
                batch.append(message)
                guard isThreadParent(message) else { continue }
                let thread = try await client.conversationReplies(channel: request.conversationID, ts: message.ts,
                                                                  credential: credential)
                if thread.hasMore { summary.complete = false }
                for reply in thread.messages where reply.ts != message.ts {
                    guard SlackDayFile.seconds(ofTS: reply.ts) != nil else { summary.skipped_messages += 1; continue }
                    if seen.insert(reply.ts).inserted { batch.append(reply) }
                }
            }
            try await write(batch, into: directory, names: &names, summary: &summary, changed: &changed)
            cursor = page.nextCursor
        } while cursor != nil && pages < maxPages
        if cursor != nil { summary.complete = false }
        summary.files = changed.sorted()
        return summary
    }

    /// After `after_ts` (strictly), else from `since_date`'s midnight on.
    /// Slack already applies `oldest`; this keeps a message Slack returns
    /// at the bound itself out.
    private func isInRange(_ ts: String) -> Bool {
        if let after = request.afterTS { return SlackDayFile.precedes(after, ts) }
        if let since = request.sinceSeconds { return (SlackDayFile.seconds(ofTS: ts) ?? 0) >= since }
        return true
    }

    /// A message that starts a thread; one Slack says has no replies is not
    /// asked about.
    private func isThreadParent(_ message: SlackMessage) -> Bool {
        message.threadTS == message.ts && message.replyCount != 0
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
