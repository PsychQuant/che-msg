import Foundation
import Testing
@testable import CheSlackMCPCore

/// spec: slack-chat-archive, "Slack day file format". Expected files are
/// written out by hand; `1793498700` is 2026-11-01 10:05 at +08:00,
/// `1793498820` 10:07, `1793451600` 2026-10-31 21:00, `1793494800`
/// 2026-11-01 09:00.
@Suite("Slack day file format")
struct SlackDayFileTests {
    static let eight = 8 * 3600

    /// spec: "Example: day file".
    static let alex = ArchivedMessage(ts: "1793498700.000100", parentTS: nil, sender: "Alex", body: "hello")
    static let ownReply = ArchivedMessage(ts: "1793498820.000200", parentTS: "1793498700.000100", sender: "我",
                                          body: "thanks")
    static let exampleFile = """
        ---
        team_id: "T01"
        conversation_id: "C01"
        date: 2026-11-01
        utc_offset: "+08:00"
        ---

        <!-- msg:1793498700.000100 -->
        **10:05 Alex**：
        hello

        <!-- msg:1793498820.000200 -->
        **10:07 我** ↳ thread:1793498700.000100：
        thanks


        """

    @Test("the spec's day file example: frontmatter, anchor, header, body, blank line; a reply header names its parent")
    func example() {
        let file = SlackDayFile.render(teamID: "T01", conversationID: "C01", day: "2026-11-01", utcOffset: "+08:00",
                                       messages: [Self.ownReply, Self.alex])
        #expect(file == Self.exampleFile)
        #expect(SlackDayFile.dayKey(ts: Self.alex.ts, offsetSeconds: Self.eight) == "2026-11-01")
    }

    /// spec: "Reply lands in its own day".
    @Test("a reply posted the day after its parent is in its own day's file; the parent's day holds the parent unchanged")
    func replyInItsOwnDay() throws {
        let parent = ArchivedMessage(ts: "1793451600.000100", parentTS: nil, sender: "Alex", body: "question")
        let reply = ArchivedMessage(ts: "1793494800.000200", parentTS: "1793451600.000100", sender: "Kim", body: "answer")

        let days = SlackDayFile.byDay([reply, parent], offsetSeconds: Self.eight)

        #expect(days.keys.sorted() == ["2026-10-31", "2026-11-01"])
        let parentDay = SlackDayFile.render(teamID: "T01", conversationID: "C01", day: "2026-10-31",
                                            utcOffset: "+08:00", messages: try #require(days["2026-10-31"]))
        let replyDay = SlackDayFile.render(teamID: "T01", conversationID: "C01", day: "2026-11-01",
                                           utcOffset: "+08:00", messages: try #require(days["2026-11-01"]))
        #expect(parentDay.hasSuffix("""
            ---

            <!-- msg:1793451600.000100 -->
            **21:00 Alex**：
            question


            """))
        #expect(replyDay.hasSuffix("""
            ---

            <!-- msg:1793494800.000200 -->
            **09:00 Kim** ↳ thread:1793451600.000100：
            answer


            """))
    }

    /// spec: a body line beginning with `<!--`, or with `**` and a time, is
    /// written with a leading backslash; a line break in a sender is a space.
    @Test("body lines shaped like an anchor or a header are escaped; a sender's line breaks become spaces")
    func escapes() {
        let message = ArchivedMessage(ts: "1793498700.000100", parentTS: nil, sender: "Al\nex\r\nChen\rLin",
                                      body: "<!-- msg:1 -->\n**09:00 Manager**：\n**9:30 x\n**bold**\n a <!-- b")
        let file = SlackDayFile.render(teamID: "T01", conversationID: "C01", day: "2026-11-01", utcOffset: "+08:00",
                                       messages: [message])
        #expect(file.hasSuffix("""
            <!-- msg:1793498700.000100 -->
            **10:05 Al ex Chen Lin**：
            \\<!-- msg:1 -->
            \\**09:00 Manager**：
            \\**9:30 x
            **bold**
             a <!-- b


            """))
    }

    @Test("blocks are ordered by ts as a number: seconds, then the fraction padded")
    func order() {
        let messages = ["1793498700.0002", "999999999.9", "1793498700.000100", "1793498700"].map {
            ArchivedMessage(ts: $0, parentTS: nil, sender: "A", body: "b")
        }
        let file = SlackDayFile.render(teamID: "T01", conversationID: "C01", day: "x", utcOffset: "+08:00",
                                       messages: messages)
        let anchors = file.split(separator: "\n").filter { $0.hasPrefix("<!-- msg:") }
        #expect(anchors == ["<!-- msg:999999999.9 -->", "<!-- msg:1793498700 -->",
                            "<!-- msg:1793498700.000100 -->", "<!-- msg:1793498700.0002 -->"])
    }

    @Test("a ts must be digits with an optional fraction, its seconds within the year 9999",
          arguments: [("1793498700.000100", Int64(1793498700)), ("1793498700", 1793498700), ("0.1", 0)] as [(String, Int64)])
    func validTimestamps(ts: String, seconds: Int64) {
        #expect(SlackDayFile.seconds(ofTS: ts) == seconds)
    }

    @Test("anything else is not a ts", arguments: ["", "abc", "1.2.3", "-1", ".5", "5.", "1793498700.0001 ",
                                                   "99999999999999999999", "253402300800", "1793498700.00010<"])
    func invalidTimestamps(ts: String) {
        #expect(SlackDayFile.seconds(ofTS: ts) == nil)
    }

    /// Merge: existing blocks are kept byte for byte, a re-archived ts is
    /// replaced, a new ts is added in order, and text before the first
    /// anchor is kept.
    @Test("merging keeps existing blocks and the preamble, replaces a re-archived ts and adds new ones in order")
    func merge() {
        let existing = """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-01
            utc_offset: "+08:00"
            ---

            my notes

            <!-- msg:1793498600.000100 -->
            **10:03 Alex**：
            edited by hand

            <!-- msg:1793498820.000200 -->
            **10:07 我**：
            old text

            """
        let rearchived = ArchivedMessage(ts: "1793498820.000200", parentTS: nil, sender: "我", body: "new text")

        let (content, added) = SlackDayFile.merged(existing: existing, teamID: "T01", conversationID: "C01",
                                                   day: "2026-11-01", utcOffset: "+08:00",
                                                   messages: [rearchived, Self.alex])

        #expect(added == ["1793498700.000100"])
        #expect(content == """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-01
            utc_offset: "+08:00"
            ---

            my notes

            <!-- msg:1793498600.000100 -->
            **10:03 Alex**：
            edited by hand

            <!-- msg:1793498700.000100 -->
            **10:05 Alex**：
            hello

            <!-- msg:1793498820.000200 -->
            **10:07 我**：
            new text


            """)
    }

    @Test("merging the same messages into the file they produced changes nothing")
    func mergeIsStable() {
        let (content, added) = SlackDayFile.merged(existing: Self.exampleFile, teamID: "T01", conversationID: "C01",
                                                   day: "2026-11-01", utcOffset: "+08:00",
                                                   messages: [Self.alex, Self.ownReply])
        #expect(content == Self.exampleFile)
        #expect(added.isEmpty)
    }
}
