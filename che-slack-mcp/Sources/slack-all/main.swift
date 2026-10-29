import ArgumentParser
import Foundation
import SlackWebLib

@main
struct SlackAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack-all",
        abstract: "Manage the Slack session credentials that che-slack-mcp uses.",
        version: "0.9.0"
    )
}
