import Foundation
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Slack markup conversion". The expected bodies
/// are the spec's literals.
@Suite("Slack markup conversion")
struct SlackMarkupTests {
    /// `U9` is `Kim`; every other user is unknown.
    static func kim(_ user: String) -> String? { user == "U9" ? "Kim" : nil }
    static func nobody(_ user: String) -> String? { nil }

    /// spec: "Mixed markup".
    @Test("a mention, a channel, a labelled link and &amp; convert together")
    func mixed() {
        let body = SlackMarkup.body(text: "<@U9> see <#C7|general> and <https://x.example|the doc> &amp; more",
                                    files: [], userName: Self.kim)
        #expect(body == "@Kim see #general and [the doc](https://x.example) & more")
    }

    /// spec: "Example: conversion cases", the four text rows.
    @Test("each text row of the conversion table", arguments: [
        ("<@U9>", "@U9"),
        ("<#C7|general>", "#general"),
        ("<https://x.example>", "https://x.example"),
        ("a &lt; b", "a < b"),
    ])
    func conversionTable(slack: String, markdown: String) {
        #expect(SlackMarkup.body(text: slack, files: [], userName: Self.nobody) == markdown)
    }

    /// spec: "Example: conversion cases", the file row.
    @Test("a message with a file and no text is the file line")
    func fileOnly() {
        let file = SlackFile(id: "F1", name: "plan.pdf", permalink: "https://t.slack.com/files/U9/F1/plan.pdf")
        #expect(SlackMarkup.body(text: nil, files: [file], userName: Self.nobody)
                == "[file: plan.pdf](https://t.slack.com/files/U9/F1/plan.pdf)")
        #expect(SlackMarkup.body(text: "", files: [file], userName: Self.nobody)
                == "[file: plan.pdf](https://t.slack.com/files/U9/F1/plan.pdf)")
    }

    /// spec: the requirement's own cases not in the table.
    @Test("a labelled link becomes a markdown link, and &gt; and &amp; are decoded")
    func requirementCases() {
        #expect(SlackMarkup.body(text: "<https://x.example|label>", files: [], userName: Self.nobody)
                == "[label](https://x.example)")
        #expect(SlackMarkup.body(text: "a &gt; b &amp; c", files: [], userName: Self.nobody) == "a > b & c")
    }

    @Test("each file is appended on its own line after the text")
    func textAndFiles() {
        let files = [SlackFile(name: "a.txt", permalink: "https://t.slack.com/files/U9/F1/a.txt"),
                     SlackFile(name: "b.png", permalink: "https://t.slack.com/files/U9/F2/b.png")]
        #expect(SlackMarkup.body(text: "two files", files: files, userName: Self.nobody)
                == "two files\n[file: a.txt](https://t.slack.com/files/U9/F1/a.txt)\n"
                + "[file: b.png](https://t.slack.com/files/U9/F2/b.png)")
    }

    /// Spec silent; chosen: a file without a permalink keeps its name
    /// without a link, a file without a name uses its title, then its id.
    @Test("a file without a permalink or name is still written, never downloaded")
    func incompleteFiles() {
        let files = [SlackFile(id: "F3", name: "gone.pdf"), SlackFile(id: "F4", title: "Notes"), SlackFile(id: "F5")]
        #expect(SlackMarkup.body(text: nil, files: files, userName: Self.nobody)
                == "[file: gone.pdf]\n[file: Notes]\n[file: F5]")
    }

    @Test("no text and no file is an empty body")
    func empty() {
        #expect(SlackMarkup.body(text: nil, files: [], userName: Self.nobody) == "")
    }

    /// Entities are decoded once, so an encoded entity stays one.
    @Test("&amp;lt; decodes to &lt;, not <")
    func singlePass() {
        #expect(SlackMarkup.body(text: "&amp;lt;", files: [], userName: Self.nobody) == "&lt;")
    }

    /// Spec silent; chosen: a channel without a label is its id, special
    /// mentions are @here / @channel / @everyone, a label wins elsewhere.
    @Test("channel without label, special mentions and an unclosed < are kept readable", arguments: [
        ("<#C7>", "#C7"),
        ("<!here> <!channel> <!everyone>", "@here @channel @everyone"),
        ("<!subteam^S1|@devs> ping", "@devs ping"),
        ("<mailto:a@b.example|a@b.example>", "[a@b.example](mailto:a@b.example)"),
        ("<@U8|kim.old>", "@kim.old"),
        ("1 <2 and &lt;3", "1 <2 and <3"),
    ])
    func otherMarkup(slack: String, markdown: String) {
        #expect(SlackMarkup.body(text: slack, files: [], userName: Self.nobody) == markdown)
    }

    @Test("the users mentioned, in order of first mention, each once")
    func mentionedUsers() {
        #expect(SlackMarkup.mentionedUsers("<@U2> hi <@U1|x> and <@U2> <#C1> <https://x.example>") == ["U2", "U1"])
    }
}
