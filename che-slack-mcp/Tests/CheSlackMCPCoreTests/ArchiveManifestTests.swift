import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Incremental archive and manifest" and
/// "Thread replies and lookback", through the tool with a fake Slack and a
/// fixed clock. Times at +08:00: the parent `1793498700.000100` is
/// 2026-11-01 10:05, the user's reply `1793498820.000200` 10:07, and the
/// first run 2026-11-01 11:05 (`1793502300`). A day is 86400 seconds.
@Suite("archive_conversation_to_markdown manifest and lookback")
struct ArchiveManifestTests {
    static let parentTS = "1793498700.000100"
    static let replyTS = "1793498820.000200"
    static let firstRun = 1_793_502_300
    static let day = 86_400
    static let manifestPath = "T01/C01/manifest.json"

    /// Alex's thread parent as `conversations.history` lists it.
    static func parent(replies: Int, latest: String) -> String {
        #"{"type":"message","user":"U02","text":"hello","ts":"1793498700.000100","thread_ts":"1793498700.000100","reply_count":\#(replies),"latest_reply":"\#(latest)"}"#
    }

    /// The fake Slack of the spec's day file example: the parent and the
    /// user's own reply.
    static func firstRunSlack() -> MethodTransport {
        let parent = parent(replies: 1, latest: replyTS)
        return ArchiveToolTests.slack(history: ArchiveFake.history([parent]),
                                      replies: ArchiveFake.replies([parent, ArchiveToolTests.ownReply]))
    }

    /// `handler` with its clock fixed at `seconds` since 1970.
    static func at(_ seconds: Int, _ handler: SlackToolHandler) -> SlackToolHandler {
        var fixed = handler
        fixed.now = { Date(timeIntervalSince1970: TimeInterval(seconds)) }
        return fixed
    }

    static func manifest(_ output: TemporaryDirectory) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(output.read(manifestPath).utf8)) as? NSDictionary)
    }

    /// A hand-written manifest, compared as parsed JSON, so a ts written as
    /// a number would not equal one written as a string.
    static func expected(_ json: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    @Test("a run writes manifest.json (0600): newest top-level ts, newest reply ts per parent, run time, counts")
    func manifestAfterFirstRun() async throws {
        let (handler, _) = try await readHandler(Self.firstRunSlack())
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)

        #expect(result.isError == false, "\(text(result))")
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", Self.manifestPath])
        #expect(try Self.manifest(output) == Self.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793498700.000100",
             "newest_reply_ts": {"1793498700.000100": "1793498820.000200"},
             "last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 1, "thread_replies": 1,
                          "new_messages": 2}}
            """))
        #expect(try output.mode(Self.manifestPath) == 0o600)
        let raw = try output.read(Self.manifestPath)
        for content in ["hello", "thanks", "Alex", "我"] {
            #expect(!raw.contains(content), "the manifest holds \(content)")
        }
    }

    /// spec: "Second run with no new messages". The second run is a day
    /// later, 2026-11-02 11:05 (`1793588700`); its 30-day window starts at
    /// `1793588700 - 30 * 86400 = 1790996700`, before the bookmark, so the
    /// history is listed from there. The parent's `latest_reply` is the
    /// reply already recorded, so its replies are not asked for again.
    @Test("spec: a second run with no new messages leaves every day file byte-identical; the manifest records its time")
    func secondRunWithNoNewMessages() async throws {
        let first = Self.firstRunSlack()
        let (handler, _) = try await readHandler(first)
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        let dayFile = try output.read("T01/C01/2026-11-01.md")
        let second = Self.firstRunSlack()
        let (secondHandler, _) = try await readHandler(second)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + Self.day, secondHandler), into: output)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":[],"lookback_complete":true,"#
                   + #""new_messages":0,"skipped_messages":0,"team_id":"T01","thread_replies":0,"#
                   + #""top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(dayFile == SlackDayFileTests.exampleFile)
        #expect(try output.read("T01/C01/2026-11-01.md") == dayFile)
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", Self.manifestPath])
        #expect(second.methods == ["conversations.history"])
        #expect(second.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1790996700"])
        #expect(try Self.manifest(output) == Self.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793498700.000100",
             "newest_reply_ts": {"1793498700.000100": "1793498820.000200"},
             "last_run": {"at": "2026-11-02T11:05:00+08:00", "top_level_messages": 0, "thread_replies": 0,
                          "new_messages": 0}}
            """))
    }

    /// A later run whose Slack lists the parent with `latest_reply` `late`
    /// and answers its replies with Kim's reply `late` added.
    static func laterSlack(late: String) -> MethodTransport {
        let parent = parent(replies: 2, latest: late)
        let reply = #"{"user":"U03","text":"late answer","ts":"\#(late)","thread_ts":"1793498700.000100"}"#
        return ArchiveToolTests.slack(history: ArchiveFake.history([parent]),
                                      replies: ArchiveFake.replies([parent, ArchiveToolTests.ownReply, reply]),
                                      names: ["U02": "Alex", "U03": "Kim"])
    }

    static let lookback30: [String: Value] = ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(30)]

    /// What the result says when every new message was written but the page
    /// limit stopped the listing of the lookback window.
    static let lookbackNote = "All new messages were written, but the page limit stopped this call before it had "
        + "listed the whole lookback window, so the thread parents in the rest of the window were not checked for "
        + "new replies. A smaller thread_lookback_days lists fewer messages."

    /// spec: "Late reply outside the window is not fetched". The second run
    /// is 45 days after the first, 2026-12-16 11:05 (`1797390300`); the
    /// window starts at `1797390300 - 30 * 86400 = 1794798300`, after the
    /// parent. The new reply `1797300300.000300` is 2026-12-15 10:05.
    @Test("spec: with thread_lookback_days 30, a 45-day-old parent's new reply is not fetched nor archived")
    func lateReplyOutsideWindow() async throws {
        let (handler, _) = try await readHandler(Self.firstRunSlack())
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        let dayFile = try output.read("T01/C01/2026-11-01.md")
        let later = Self.laterSlack(late: "1797300300.000300")
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + 45 * Self.day, laterHandler), into: output,
                                                    Self.lookback30)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":[],"lookback_complete":true,"#
                   + #""new_messages":0,"skipped_messages":0,"team_id":"T01","thread_replies":0,"#
                   + #""top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(later.methods == ["conversations.history"])
        #expect(later.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1793498700.000100"])
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", Self.manifestPath])
        #expect(try output.read("T01/C01/2026-11-01.md") == dayFile)
        // The parent left the window, so its reply record is dropped.
        #expect(try Self.manifest(output) == Self.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793498700.000100", "newest_reply_ts": {},
             "last_run": {"at": "2026-12-16T11:05:00+08:00", "top_level_messages": 0, "thread_replies": 0,
                          "new_messages": 0}}
            """))
    }

    /// The counterpart inside the window: 20 days after the first run,
    /// 2026-11-21 11:05 (`1795230300`), the window starts at
    /// `1795230300 - 30 * 86400 = 1792638300`, before the bookmark, so the
    /// history is listed from there. Kim's reply `1795140300.000300` is
    /// 2026-11-20 10:05, newer than the recorded `1793498820.000200`.
    @Test("a parent inside the window whose latest_reply is newer than recorded gets its new reply archived")
    func lateReplyInsideWindow() async throws {
        let (handler, _) = try await readHandler(Self.firstRunSlack())
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        let dayFile = try output.read("T01/C01/2026-11-01.md")
        let later = Self.laterSlack(late: "1795140300.000300")
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + 20 * Self.day, laterHandler), into: output,
                                                    Self.lookback30)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-11-20.md"],"#
                   + #""lookback_complete":true,"new_messages":1,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":2,"top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(later.methods == ["conversations.history", "conversations.replies", "users.info"])
        #expect(later.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1792638300"])
        #expect(later.calls.dropFirst().first?.parameters["ts"] == Self.parentTS)
        #expect(try output.read("T01/C01/2026-11-01.md") == dayFile)
        #expect(try output.read("T01/C01/2026-11-20.md") == """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-20
            utc_offset: "+08:00"
            ---

            <!-- msg:1795140300.000300 -->
            **10:05 Kim** ↳ thread:1793498700.000100：
            late answer


            """)
        #expect(try Self.manifest(output) == Self.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793498700.000100",
             "newest_reply_ts": {"1793498700.000100": "1795140300.000300"},
             "last_run": {"at": "2026-11-21T11:05:00+08:00", "top_level_messages": 0, "thread_replies": 2,
                          "new_messages": 1}}
            """))
    }

    /// A fake Slack holding `threads` (newest first): each parent, from Alex,
    /// with its replies (ts, oldest first), each from Kim. History honours
    /// `oldest`; replies honour `oldest` and send the parent first.
    static func threads(_ threads: [(parent: String, replies: [String])]) -> MethodTransport {
        let parentJSON = { (thread: (parent: String, replies: [String])) in
            ArchiveUnfinishedThreadTests.parentJSON(thread.parent, replies: thread.replies.count,
                                                    latest: thread.replies.last ?? "")
        }
        return MethodTransport { call in
            switch call.method {
            case "conversations.history":
                let listed = threads.filter { thread in
                    call.parameters["oldest"].map { SlackDayFile.precedes($0, thread.parent) } ?? true
                }
                return .body(ArchiveFake.history(listed.map(parentJSON)))
            case "conversations.replies":
                guard let thread = threads.first(where: { $0.parent == call.parameters["ts"] }) else {
                    return .body(Fake.slackError("thread_not_found"))
                }
                let after = thread.replies.filter { ts in
                    call.parameters["oldest"].map { SlackDayFile.precedes($0, ts) } ?? true
                }
                return .body(ArchiveFake.replies([parentJSON(thread)] + after.map {
                    #"{"user":"U03","text":"r","ts":"\#($0)","thread_ts":"\#(thread.parent)"}"#
                }))
            default: return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        }
    }

    /// spec: "Lookback skips a parent that was never archived". The first
    /// call (2026-11-01 11:05) archives from since_date 2026-10-25 at +08:00
    /// (`1792857600`): the parent `1792980000.000100` (2026-10-26 10:00) and
    /// its reply at 11:00, `1792983600.000200`. The parent
    /// `1792461600.000100` (2026-10-20 10:00), whose reply is
    /// `1792548000.000200` (10-21 10:00), is older and not archived. The next
    /// call, without since_date, is a day later; its 30-day window starts at
    /// `1793588700 - 30 * 86400 = 1790996700` (2026-10-02), so both parents
    /// are listed. Only the one in its day file gets its replies fetched,
    /// and its new reply `1793066400.000300` (10-27 10:00) is written.
    @Test("spec: a parent listed only for the lookback window and never archived gets no replies; an archived one does")
    func lookbackSkipsUnarchivedParent() async throws {
        let (kept, keptReply, lateReply) = ("1792980000.000100", "1792983600.000200", "1793066400.000300")
        let (unarchived, unarchivedReply) = ("1792461600.000100", "1792548000.000200")
        let output = TemporaryDirectory()
        defer { output.remove() }
        let first = Self.threads([(kept, [keptReply]), (unarchived, [unarchivedReply])])
        let (firstHandler, _) = try await readHandler(first)
        let firstResult = await ArchiveToolTests.archive(Self.at(Self.firstRun, firstHandler), into: output,
                                                         ["utc_offset": .string("+08:00"),
                                                          "since_date": .string("2026-10-25")])
        #expect(text(firstResult).contains(#""new_messages":2"#), "\(text(firstResult))")
        let dayFile = try output.read("T01/C01/2026-10-26.md")
        let later = Self.threads([(kept, [keptReply, lateReply]), (unarchived, [unarchivedReply])])
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + Self.day, laterHandler), into: output,
                                                    Self.lookback30)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-10-27.md"],"#
                   + #""lookback_complete":true,"new_messages":1,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":1,"top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(later.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1790996700"])
        #expect(later.calls.filter { $0.method == "conversations.replies" }.map { $0.parameters }
                    == [["channel": "C01", "limit": "200", "ts": kept, "oldest": keptReply]])
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-10-26.md", "T01/C01/2026-10-27.md",
                                     Self.manifestPath])
        #expect(try output.read("T01/C01/2026-10-26.md") == dayFile)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(kept)", "newest_reply_ts": {"\(kept)": "\(lateReply)"}
            """))
    }

    /// Silent-gap guard: the 50-page limit stopped a first run before the
    /// oldest message, so the bookmark stays null and the manifest records
    /// where the walk continues: it started at page 0's `1793498000.000100`
    /// and wrote down to page 49's `1793498000 - 49 = 1793497951.000100`;
    /// the next call continues below that (ArchiveContinuationTests). Not
    /// complete, and the window was not listed either; no note, as the
    /// lookback note is only for a complete run.
    @Test("a run cut by the page limit before its lower bound leaves newest_ts null and records where it continues")
    func pageCapKeepsBookmark() async throws {
        let transport = MethodTransport { call in
            guard call.method == "conversations.history" else { return ArchiveFake.users(["U02": "Alex"], call) }
            let page = Int(call.parameters["cursor"] ?? "0") ?? 0
            return .body(ArchiveFake.history([#"{"user":"U02","text":"m","ts":"\#(1793498000 - page).000100"}"#],
                                             cursor: String(page + 1)))
        }
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)

        #expect(text(result).contains(#""complete":false"#) && text(result).contains(#""lookback_complete":false"#)
                    && !text(result).contains(#""note""#), "\(text(result))")
        #expect(try Self.manifest(output) == Self.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": null, "newest_reply_ts": {},
             "continuation": {"top_ts": "1793498000.000100", "below_ts": "1793497951.000100"},
             "last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 50, "thread_replies": 0,
                          "new_messages": 50}}
            """))
    }

    /// The limit stops the walk inside the lookback window, after it passed
    /// the bookmark: every message newer than the bookmark was read, so the
    /// bookmark moves, no continuation is recorded and the call is complete;
    /// only the window parents below where it stopped were left unchecked,
    /// which `lookback_complete` false and the note say. The second run is
    /// 2026-11-02 11:05; its new message `1793585100.000100` is 10:05 that
    /// day.
    @Test("a run cut by the page limit after passing the bookmark moves newest_ts and is complete, its lookback not")
    func pageCapAfterBookmark() async throws {
        let (handler, _) = try await readHandler(ArchiveToolTests.slack(
            history: ArchiveFake.history([ArchiveToolTests.alexPlain])))
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        let later = MethodTransport { call in
            guard call.method == "conversations.history" else { return ArchiveFake.users(["U02": "Alex"], call) }
            let page = Int(call.parameters["cursor"] ?? "0") ?? 0
            let ts = page == 0 ? "1793585100.000100" : "\(1793498700 - page).000100"
            return .body(ArchiveFake.history([#"{"user":"U02","text":"m","ts":"\#(ts)"}"#], cursor: String(page + 1)))
        }
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + Self.day, laterHandler), into: output)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-11-02.md"],"#
                   + #""lookback_complete":false,"new_messages":1,"note":"\#(Self.lookbackNote)","#
                   + #""skipped_messages":0,"team_id":"T01","thread_replies":0,"top_level_messages":1,"#
                   + #""utc_offset":"+08:00"}"#)
        #expect(later.calls.filter { $0.method == "conversations.history" }.count == 50)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "1793585100.000100", "newest_reply_ts": {}
            """))
    }

    /// spec: "Busy lookback window does not keep complete false", modelled
    /// with a page limit of 2 pages (400 messages) instead of 50 (10000), so
    /// 1000 older messages stand for the 12000. The bookmark is
    /// `1793451600.000100` (2026-10-31 21:00); the 10 new messages are a
    /// minute apart from `1793498700.000100` to `1793499240.000100`
    /// (2026-11-01 10:05 to 10:14); the older ones a minute apart below the
    /// bookmark down to `1793451600 - 60 * 1000 = 1793391600.000100`, all
    /// inside the 30-day window, which starts at `1793502300 - 30 * 86400 =
    /// 1790910300`. No thread is recorded as cut.
    @Test("spec: 10 new messages and a window longer than the page limit: complete true, lookback_complete false, a note")
    func busyLookbackWindow() async throws {
        let new = (0..<10).reversed().map { "\(1_793_498_700 + 60 * $0).000100" }
        let older = (1...1000).map { "\(1_793_451_600 - 60 * $0).000100" }
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""1793451600.000100""#,
        ]))
        let slack = ArchiveRangeTests.paged(new + ["1793451600.000100"] + older)
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveRangeTests.at(Self.firstRun, pages: 2, handler),
                                                    into: output, Self.lookback30)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":false,"new_messages":10,"note":"\#(Self.lookbackNote)","#
                   + #""skipped_messages":0,"team_id":"T01","thread_replies":0,"top_level_messages":10,"#
                   + #""utc_offset":"+08:00"}"#)
        #expect(ArchiveRangeTests.history(slack).map { $0.parameters["oldest"] } == ["1790910300", "1790910300"])
        #expect(ArchiveRangeTests.history(slack).last?.parameters["cursor"] == "200")
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "1793499240.000100", "newest_reply_ts": {}
            """))
        let anchors = try ArchiveContinuationTests.anchors(output)
        #expect(anchors.count == 10 && anchors.allSatisfy { line in new.contains { line.contains($0) } })
    }

    /// A parent archived before it had replies has no reply record; its
    /// first reply, a day later, is fetched and lands in the spec's example
    /// day file.
    @Test("a parent archived without replies gets its first reply fetched while inside the window")
    func firstReplyAfterArchiving() async throws {
        let (handler, _) = try await readHandler(ArchiveToolTests.slack(
            history: ArchiveFake.history([ArchiveToolTests.alexPlain])))
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        #expect(try Self.manifest(output)["newest_reply_ts"] as? NSDictionary == [:])
        let later = Self.firstRunSlack()
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + Self.day, laterHandler), into: output)

        #expect(text(result).contains(#""new_messages":1"#), "\(text(result))")
        #expect(later.methods == ["conversations.history", "conversations.replies"])
        #expect(try output.read("T01/C01/2026-11-01.md") == SlackDayFileTests.exampleFile)
        #expect(try Self.manifest(output)["newest_reply_ts"] as? NSDictionary == [Self.parentTS: Self.replyTS])
    }

    /// spec: "Without after_ts and since_date, a run SHALL fetch only
    /// top-level messages newer than the manifest's newest top-level ts."
    /// With a 0-day window the bookmark is `oldest` itself; an older message
    /// Slack still returns (here edited) is not written again.
    @Test("with thread_lookback_days 0 the bookmark is sent as oldest and only newer messages are written")
    func onlyNewerThanBookmark() async throws {
        let (handler, _) = try await readHandler(ArchiveToolTests.slack(
            history: ArchiveFake.history([ArchiveToolTests.alexPlain])))
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        let dayFile = try output.read("T01/C01/2026-11-01.md")
        let later = ArchiveToolTests.slack(history: ArchiveFake.history([
            #"{"user":"U02","text":"new","ts":"1793585100.000100"}"#,
            #"{"user":"U02","text":"edited","ts":"1793498700.000100"}"#,
        ]))
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + Self.day, laterHandler), into: output,
                                                    ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(0)])

        #expect(text(result).contains(#""files":["T01/C01/2026-11-02.md"]"#), "\(text(result))")
        #expect(later.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1793498700.000100"])
        #expect(try output.read("T01/C01/2026-11-01.md") == dayFile)
        #expect(try Self.manifest(output) == Self.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793585100.000100", "newest_reply_ts": {},
             "last_run": {"at": "2026-11-02T11:05:00+08:00", "top_level_messages": 1, "thread_replies": 0,
                          "new_messages": 1}}
            """))
    }

    /// after_ts below the bookmark archives that range again (the blocks
    /// already there are kept) and never moves the bookmark back.
    @Test("after_ts takes precedence over the manifest's bookmark, which is not moved back")
    func afterTSOverridesBookmark() async throws {
        let (handler, _) = try await readHandler(ArchiveToolTests.slack(
            history: ArchiveFake.history([ArchiveToolTests.alexPlain])))
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)
        let later = ArchiveToolTests.slack(history: ArchiveFake.history([
            #"{"user":"U02","text":"earlier","ts":"1793498600.000100"}"#,
        ]))
        let (laterHandler, _) = try await readHandler(later)

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun + Self.day, laterHandler), into: output, [
            "utc_offset": .string("+08:00"), "thread_lookback_days": .int(0), "after_ts": .string("1793498000.000100"),
        ])

        #expect(text(result).contains(#""new_messages":1"#), "\(text(result))")
        #expect(later.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1793498000.000100"])
        #expect(try output.read("T01/C01/2026-11-01.md").contains("<!-- msg:1793498600.000100 -->\n**10:03 Alex**：\nearlier\n"))
        #expect(try Self.manifest(output)["newest_ts"] as? String == "1793498700.000100")
    }

    @Test("the manifest holds no message text, sender name, bot name, file name or permalink")
    func manifestIsContentFree() async throws {
        let parent = #"{"user":"U02","text":"secret plan","ts":"1793498700.000100","thread_ts":"1793498700.000100","reply_count":1,"latest_reply":"1793498820.000200","files":[{"id":"F1","name":"plan.pdf","permalink":"https://t.slack.com/files/U9/F1/plan.pdf"}]}"#
        let history = ArchiveFake.history([
            #"{"subtype":"bot_message","bot_id":"B01","username":"deploybot","text":"deployed","ts":"1793498710.000100"}"#,
            parent,
        ])
        let reply = #"{"user":"U03","text":"agreed","ts":"1793498820.000200","thread_ts":"1793498700.000100"}"#
        let (handler, _) = try await readHandler(ArchiveToolTests.slack(
            history: history, replies: ArchiveFake.replies([parent, reply]), names: ["U02": "Alex", "U03": "Kim"]))
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await ArchiveToolTests.archive(Self.at(Self.firstRun, handler), into: output)

        #expect(result.isError == false, "\(text(result))")
        #expect(try output.read("T01/C01/2026-11-01.md").contains("[file: plan.pdf]"))
        let raw = try output.read(Self.manifestPath)
        for content in ["secret", "plan", "deploy", "agreed", "Alex", "Kim", "https", "F1", "U02", "U03", "B01"] {
            #expect(!raw.contains(content), "the manifest holds \(content)")
        }
    }
}
