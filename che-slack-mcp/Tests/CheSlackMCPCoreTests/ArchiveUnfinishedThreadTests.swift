import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Thread replies and lookback": a thread cut
/// by the reply page limit (5 pages of 200) keeps its reply bookmark and
/// is listed in the manifest's `unfinished_threads` whatever its parent's
/// age, and every later run continues it with `conversations.replies`
/// until all its replies are written; until then the run is not complete.
/// Times at +08:00; runs are at 2026-11-01 11:05 (`1793502300`).
@Suite("archive_conversation_to_markdown unfinished threads")
struct ArchiveUnfinishedThreadTests {
    /// 2026-09-02 11:00, 60 days and 5 minutes before the first run.
    static let oldParent = "1788318000.000100"
    /// The old parent's 1300 replies, one second apart: the 1000th is
    /// `1788319000.000200`, the last `1788319300.000200`.
    static let oldReplies = (1...1300).map { "\(1_788_318_000 + $0).000200" }
    static let thousandth = "1788319000.000200"

    static func parentJSON(_ ts: String, replies: Int, latest: String) -> String {
        #"{"user":"U02","text":"question","ts":"\#(ts)","thread_ts":"\#(ts)","reply_count":\#(replies),"latest_reply":"\#(latest)"}"#
    }

    /// History holds only `parent` (listed when `oldest` is below it);
    /// `replies` answers `conversations.replies`.
    static func slack(parent: String, parentTS: String,
                      replies: @escaping @Sendable (SlackCall) -> ScriptedAnswer) -> MethodTransport {
        MethodTransport { call in
            switch call.method {
            case "conversations.history":
                let listed = call.parameters["oldest"].map { SlackDayFile.precedes($0, parentTS) } ?? true
                return .body(ArchiveFake.history(listed ? [parent] : []))
            case "conversations.replies": return replies(call)
            default: return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        }
    }

    static func oldThread() -> MethodTransport {
        let parent = parentJSON(oldParent, replies: 1300, latest: oldReplies.last ?? "")
        return slack(parent: parent, parentTS: oldParent) {
            PagedSlack.replies(parent: parent, parentTS: oldParent, oldReplies, $0)
        }
    }

    static func replies(_ transport: MethodTransport) -> [SlackCall] {
        transport.calls.filter { $0.method == "conversations.replies" }
    }

    /// A manifest after a first run cut the old thread at its 1000th reply.
    static let cutOldThread = ArchiveManifestSafetyTests.manifest([
        "newest_ts": #""\#(oldParent)""#,
        "newest_reply_ts": #"{"\#(oldParent)": "\#(thousandth)"}"#,
        "unfinished_threads": #"["\#(oldParent)"]"#,
    ])

    /// spec: "Long thread outside the window continues", also with a 0-day
    /// window. The second call is a day later; its window, if any, starts
    /// after the parent, so the history is listed from the bookmark and the
    /// parent is not listed again.
    @Test("spec: a 1300-reply thread 60 days old is archived to its 1000th reply, then the rest although outside the window",
          arguments: [30, 0])
    func longThreadOutsideWindow(lookback: Int) async throws {
        let options: [String: Value] = ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(lookback)]
        let output = TemporaryDirectory()
        defer { output.remove() }
        let first = Self.oldThread()
        let (firstHandler, _) = try await readHandler(first)

        let firstResult = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun,
                                                                                 firstHandler), into: output, options)

        expectJSON(firstResult, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-09-02.md"],"#
                   + #""lookback_complete":true,"new_messages":1001,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":1000,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(Self.oldParent)", "newest_reply_ts": {"\(Self.oldParent)": "\(Self.thousandth)"},
            "unfinished_threads": ["\(Self.oldParent)"]
            """))
        let second = Self.oldThread()
        let (secondHandler, _) = try await readHandler(second)

        let secondResult = await ArchiveToolTests.archive(
            ArchiveManifestTests.at(ArchiveManifestTests.firstRun + ArchiveManifestTests.day, secondHandler),
            into: output, options)

        expectJSON(secondResult, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-09-02.md"],"#
                   + #""lookback_complete":true,"new_messages":300,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":300,"top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(second.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": Self.oldParent])
        #expect(Self.replies(second).map { $0.parameters["cursor"] } == [nil, "200"])
        #expect(Self.replies(second).allSatisfy {
            $0.parameters["oldest"] == Self.thousandth && $0.parameters["ts"] == Self.oldParent
        }, "\(Self.replies(second))")
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(Self.oldParent)", "newest_reply_ts": {}
            """))
        let anchors = try ArchiveContinuationTests.anchors(output)
        #expect(anchors.count == 1301 && Set(anchors).count == 1301)
    }

    /// Every run continues a recorded unfinished thread, an explicit range
    /// included, and the parent itself is not written again.
    @Test("a recorded unfinished thread is continued by a default call, a 0-day window and an after_ts range alike",
          arguments: [["utc_offset": .string("+08:00")],
                      ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(0)],
                      ["utc_offset": .string("+08:00"), "after_ts": .string(oldParent)]] as [[String: Value]])
    func unfinishedThreadContinued(_ options: [String: Value]) async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: Self.cutOldThread)
        let slack = Self.oldThread()
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, options)

        #expect(text(result).contains(#""complete":true"#) && text(result).contains(#""thread_replies":300"#)
                    && text(result).contains(#""top_level_messages":0"#), "\(text(result))")
        #expect(Self.replies(slack).allSatisfy { $0.parameters["oldest"] == Self.thousandth })
        #expect(try !output.read("T01/C01/2026-09-02.md").contains("<!-- msg:\(Self.oldParent) -->"))
        #expect(try ArchiveManifestTests.manifest(output)["unfinished_threads"] == nil)
    }

    /// A cut thread inside the window whose parent the walk lists is
    /// fetched there; the continuation of unfinished threads after the walk
    /// does not fetch it again. Its 1100 replies after the recorded
    /// `1793451700.000200` take more than one walk, so it stays unfinished,
    /// its bookmark moved to `1793451700 + 1000 = 1793452700.000200`.
    @Test("a cut thread the walk lists inside the window is fetched once per run, and stays listed while still cut")
    func listedUnfinishedThreadFetchedOnce() async throws {
        let parentTS = "1793451600.000100"
        let replies = (1...1200).map { "\(1_793_451_600 + $0).000200" }
        let parent = Self.parentJSON(parentTS, replies: 1200, latest: replies.last ?? "")
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(parentTS)""#,
            "newest_reply_ts": #"{"\#(parentTS)": "1793451700.000200"}"#,
            "unfinished_threads": #"["\#(parentTS)"]"#,
        ]))
        let slack = Self.slack(parent: parent, parentTS: parentTS) {
            PagedSlack.replies(parent: parent, parentTS: parentTS, replies, $0)
        }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output)

        #expect(text(result).contains(#""complete":false"#) && text(result).contains(#""thread_replies":1000"#),
                "\(text(result))")
        #expect(Self.replies(slack).count == SlackWebClient.repliesMaxPages, "\(Self.replies(slack))")
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(parentTS)", "newest_reply_ts": {"\(parentTS)": "1793452700.000200"},
            "unfinished_threads": ["\(parentTS)"]
            """))
    }

    /// A rate limit while continuing an unfinished thread is a stop like
    /// any other: the reply bookmark and the list do not move, and nothing
    /// to continue was written, so the manifest is left byte-identical.
    @Test("a rate limit while continuing an unfinished thread leaves its bookmark, the list and the manifest as they were")
    func unfinishedThreadRateLimited() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: Self.cutOldThread)
        let parent = Self.parentJSON(Self.oldParent, replies: 1300, latest: Self.oldReplies.last ?? "")
        let slack = Self.slack(parent: parent, parentTS: Self.oldParent) { _ in ArchivePartialProgressTests.rateLimited }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output)

        #expect(result.isError == false, "\(text(result))")
        #expect(text(result).contains(#""stopped_reason":"rate_limited""#), "\(text(result))")
        #expect(Self.replies(slack).first?.parameters["oldest"] == Self.thousandth)
        #expect(try output.read(ArchiveManifestTests.manifestPath) == Self.cutOldThread)
    }

    /// 2026-09-02 10:00 and 09:00: top-level messages below the old parent.
    static let olderTS = "1788314400.000100"
    static let oldestTS = "1788310800.000100"

    /// History page 1 holds the old parent (1300 replies) and `olderTS`
    /// and offers cursor `c2`, which `second` answers; `replies` answers
    /// `conversations.replies` for any other parent than the old one.
    /// users.info knows Alex (U02) and Kim (U03) and keeps rate limiting U05.
    static func cutThenStopped(second: ScriptedAnswer,
                               replies other: @escaping @Sendable (SlackCall) -> ScriptedAnswer = { _ in
                                   .body(Fake.slackError("no_scripted_answer"))
                               }) -> MethodTransport {
        let parent = parentJSON(oldParent, replies: 1300, latest: oldReplies.last ?? "")
        let older = #"{"user":"U02","text":"m","ts":"\#(olderTS)"}"#
        return MethodTransport { call in
            switch (call.method, call.parameters["cursor"]) {
            case ("conversations.history", nil): return .body(ArchiveFake.history([parent, older], cursor: "c2"))
            case ("conversations.history", _): return second
            case ("conversations.replies", _):
                guard call.parameters["ts"] == oldParent else { return other(call) }
                return PagedSlack.replies(parent: parent, parentTS: oldParent, oldReplies, call)
            default:
                return call.parameters["user"] == "U05"
                    ? ArchivePartialProgressTests.rateLimited : ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        }
    }

    /// spec: "Thread cut before a rate limit continues". The first archive
    /// writes the old parent with its first 1000 replies and `olderTS`, then
    /// Slack keeps rate limiting page 2. The walk continues below `olderTS`,
    /// under the parent, so only the manifest's record of the cut thread
    /// brings back the other 300: the second call (an hour later) continues
    /// the walk, writes `oldestTS` and the 300 replies, and moves newest_ts
    /// to the walk's top; nothing newer was looked for, so it is not
    /// complete. The third call finds nothing newer and is.
    @Test("spec: a thread cut at its 1000th reply before a rate limit is recorded, and the next calls archive the other 300")
    func threadCutBeforeRateLimitContinues() async throws {
        let options = ArchiveManifestTests.lookback30
        let output = TemporaryDirectory()
        defer { output.remove() }
        let first = Self.cutThenStopped(second: ArchivePartialProgressTests.rateLimited)
        let (firstHandler, _) = try await readHandler(first)

        let firstResult = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun,
                                                                                 firstHandler), into: output, options)

        expectJSON(firstResult, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-09-02.md"],"#
                   + #""lookback_complete":false,"new_messages":1002,"#
                   + #""note":"\#(ArchivePartialProgressTests.note("1002 messages"))","retry_after_seconds":30,"#
                   + #""skipped_messages":0,"stopped_reason":"rate_limited","team_id":"T01","thread_replies":1000,"#
                   + #""top_level_messages":2,"utc_offset":"+08:00"}"#)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": null, "newest_reply_ts": {"\(Self.oldParent)": "\(Self.thousandth)"},
            "continuation": {"top_ts": "\(Self.oldParent)", "below_ts": "\(Self.olderTS)"},
            "unfinished_threads": ["\(Self.oldParent)"]
            """))
        let all = [Self.oldParent, Self.olderTS, Self.oldestTS]
        let rest = { MethodTransport { call in
            switch call.method {
            case "conversations.history": return PagedSlack.history(all, call)
            case "conversations.replies":
                let parent = Self.parentJSON(Self.oldParent, replies: 1300, latest: Self.oldReplies.last ?? "")
                return PagedSlack.replies(parent: parent, parentTS: Self.oldParent, Self.oldReplies, call)
            default: return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        } }
        let second = rest()
        let (secondHandler, _) = try await readHandler(second)

        let secondResult = await ArchiveToolTests.archive(
            ArchiveManifestTests.at(ArchiveManifestTests.firstRun + 3600, secondHandler), into: output, options)

        expectJSON(secondResult, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-09-02.md"],"#
                   + #""lookback_complete":true,"new_messages":301,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":300,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(second.calls.first?.parameters == ["channel": "C01", "limit": "200", "latest": Self.olderTS])
        #expect(Self.replies(second).allSatisfy {
            $0.parameters["oldest"] == Self.thousandth && $0.parameters["ts"] == Self.oldParent
        }, "\(Self.replies(second))")
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(Self.oldParent)", "newest_reply_ts": {}
            """))
        let third = rest()
        let (thirdHandler, _) = try await readHandler(third)

        let thirdResult = await ArchiveToolTests.archive(
            ArchiveManifestTests.at(ArchiveManifestTests.firstRun + 7200, thirdHandler), into: output, options)

        expectJSON(thirdResult, #"{"complete":true,"conversation_id":"C01","files":[],"lookback_complete":true,"#
                   + #""new_messages":0,"skipped_messages":0,"team_id":"T01","thread_replies":0,"#
                   + #""top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(third.methods == ["conversations.history"])
        let anchors = try ArchiveContinuationTests.anchors(output)
        #expect(anchors.count == 1303 && Set(anchors).count == 1303)
    }

    /// A message is written only with its sender's name: page 2 holds a
    /// second cut thread, whose parent's sender (U05) Slack keeps rate
    /// limiting, so neither it nor its 1000 replies are written. Only the
    /// thread cut on page 1, whose replies were written, is recorded; the
    /// next call lists the second parent again below `olderTS` and reads its
    /// replies from the first. `1788300000.000100` is 2026-09-02 06:00.
    @Test("a cut thread whose batch was not written gets no reply bookmark; the one written before it is recorded")
    func unwrittenCutThreadNotRecorded() async throws {
        let otherTS = "1788300000.000100"
        let otherReplies = (1...1300).map { "\(1_788_300_000 + $0).000300" }
        let other = #"{"user":"U05","text":"q","ts":"\#(otherTS)","thread_ts":"\#(otherTS)","reply_count":1300,"latest_reply":"\#(otherReplies.last ?? "")"}"#
        let output = TemporaryDirectory()
        defer { output.remove() }
        let slack = Self.cutThenStopped(second: .body(ArchiveFake.history([other]))) { call in
            PagedSlack.replies(parent: other, parentTS: otherTS, otherReplies, call)
        }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, ArchiveManifestTests.lookback30)

        #expect(text(result).contains(#""stopped_reason":"rate_limited""#)
                    && text(result).contains(#""thread_replies":1000"#), "\(text(result))")
        #expect(Self.replies(slack).filter { $0.parameters["ts"] == otherTS }.count == SlackWebClient.repliesMaxPages)
        let file = try output.read("T01/C01/2026-09-02.md")
        #expect(!file.contains(otherTS) && !file.contains(".000300 -->"), "the unwritten thread is in the day file")
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": null, "newest_reply_ts": {"\(Self.oldParent)": "\(Self.thousandth)"},
            "continuation": {"top_ts": "\(Self.oldParent)", "below_ts": "\(Self.olderTS)"},
            "unfinished_threads": ["\(Self.oldParent)"]
            """))
    }

    /// A thread the manifest lists is continued, still cut, and its 1000
    /// replies written; the next listed thread is then rate limited. The
    /// first moves to its 1000th reply after the recorded one,
    /// `1788318001 + 1000 = 1788319001.000200`; the second keeps its
    /// bookmark. `1788400000.000100` is 2026-09-03 09:46:40. The walk had
    /// listed its whole range before the stop, so `lookback_complete` is
    /// true.
    @Test("a listed thread continued and still cut before a rate limit moves its bookmark; the stopped one keeps its own")
    func continuedCutThreadBeforeRateLimit() async throws {
        let stoppedTS = "1788400000.000100"
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(stoppedTS)""#,
            "newest_reply_ts": #"{"\#(Self.oldParent)": "1788318001.000200", "\#(stoppedTS)": "1788400100.000300"}"#,
            "unfinished_threads": #"["\#(Self.oldParent)", "\#(stoppedTS)"]"#,
        ]))
        let parent = Self.parentJSON(Self.oldParent, replies: 1300, latest: Self.oldReplies.last ?? "")
        let slack = MethodTransport { call in
            switch (call.method, call.parameters["ts"]) {
            case ("conversations.history", _): return .body(ArchiveFake.history([]))
            case ("conversations.replies", Self.oldParent?):
                return PagedSlack.replies(parent: parent, parentTS: Self.oldParent, Self.oldReplies, call)
            case ("conversations.replies", _): return ArchivePartialProgressTests.rateLimited
            default: return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output)

        #expect(text(result).contains(#""stopped_reason":"rate_limited""#) && text(result).contains(#""complete":false"#)
                    && text(result).contains(#""lookback_complete":true"#)
                    && text(result).contains(#""thread_replies":1000"#), "\(text(result))")
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(stoppedTS)",
            "newest_reply_ts": {"\(Self.oldParent)": "1788319001.000200", "\(stoppedTS)": "1788400100.000300"},
            "unfinished_threads": ["\(Self.oldParent)", "\(stoppedTS)"]
            """))
    }

    /// Spec silent, chosen: Slack answers `thread_not_found` when the parent
    /// is gone (deleted, or removed by a retention policy). There are no
    /// replies left to write, so the thread leaves the list instead of
    /// failing every later call.
    @Test("an unfinished thread Slack no longer finds leaves the list, and the call is not an error")
    func unfinishedThreadGone() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: Self.cutOldThread)
        let parent = Self.parentJSON(Self.oldParent, replies: 1300, latest: Self.oldReplies.last ?? "")
        let slack = Self.slack(parent: parent, parentTS: Self.oldParent) { _ in
            .body(Fake.slackError("thread_not_found"))
        }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output)

        #expect(text(result).contains(#""complete":true"#), "\(text(result))")
        #expect(Self.replies(slack).count == 1)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(Self.oldParent)", "newest_reply_ts": {}
            """))
    }

    /// spec: "Incremental archive and manifest": Slack's `has_more: true`
    /// without a next cursor on a thread's replies is a thread cut short,
    /// as by the reply page limit. The first archive writes the spec's
    /// example parent and the reply Slack returned; the thread is listed as
    /// unfinished with that reply as its bookmark, and the call is not
    /// complete.
    @Test("a thread whose replies answer has_more without a next cursor stays in unfinished_threads")
    func repliesHasMoreWithoutCursor() async throws {
        let parent = ArchiveManifestTests.parent(replies: 2, latest: "1793498880.000300")
        let replies = #"{"ok":true,"messages":[\#(parent),\#(ArchiveToolTests.ownReply)],"has_more":true}"#
        let slack = ArchiveToolTests.slack(history: ArchiveFake.history([parent]), replies: replies)
        let (handler, _) = try await readHandler(slack)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":true,"new_messages":2,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":1,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(Self.replies(slack).count == 1)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "\(ArchiveManifestTests.parentTS)",
            "newest_reply_ts": {"\(ArchiveManifestTests.parentTS)": "\(ArchiveManifestTests.replyTS)"},
            "unfinished_threads": ["\(ArchiveManifestTests.parentTS)"]
            """))
    }
}
