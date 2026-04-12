import ArgumentParser
import Foundation
import TelegramBotAPI

@main
struct TelegramBot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "telegram-bot",
        abstract: "Telegram Bot API CLI",
        subcommands: [Me.self, Send.self, Updates.self, Chat.self, Forward.self, Delete.self]
    )
}

// MARK: - Shared

extension TelegramBot {
    static func makeAPI() throws -> TelegramAPI {
        guard let token = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] else {
            throw ValidationError("TELEGRAM_BOT_TOKEN environment variable not set")
        }
        return TelegramAPI(token: token)
    }

    static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

// MARK: - Commands

extension TelegramBot {
    struct Me: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get bot info")

        func run() async throws {
            let api = try TelegramBot.makeAPI()
            try TelegramBot.printJSON(try await api.getMe())
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a text message")

        @Argument(help: "Chat ID or @channel_username")
        var chatID: String

        @Argument(help: "Message text")
        var text: String

        @Option(name: .long, help: "Parse mode: Markdown, MarkdownV2, or HTML")
        var parseMode: String?

        @Option(name: .long, help: "Message ID to reply to")
        var replyTo: Int?

        func run() async throws {
            let api = try TelegramBot.makeAPI()
            let result = try await api.sendMessage(
                chatId: chatID,
                text: text,
                parseMode: parseMode,
                replyToMessageId: replyTo
            )
            try TelegramBot.printJSON(result)
        }
    }

    struct Updates: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get incoming updates")

        @Option(name: .long, help: "Update offset")
        var offset: Int?

        @Option(name: .long, help: "Max updates (1-100)")
        var limit: Int?

        @Option(name: .long, help: "Long polling timeout in seconds")
        var timeout: Int?

        func run() async throws {
            let api = try TelegramBot.makeAPI()
            let result = try await api.getUpdates(offset: offset, limit: limit, timeout: timeout)
            try TelegramBot.printJSON(result)
        }
    }

    struct Chat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get chat info")

        @Argument(help: "Chat ID or @channel_username")
        var chatID: String

        func run() async throws {
            let api = try TelegramBot.makeAPI()
            try TelegramBot.printJSON(try await api.getChat(chatId: chatID))
        }
    }

    struct Forward: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forward a message")

        @Argument(help: "Target chat ID")
        var chatID: String

        @Argument(help: "Source chat ID")
        var fromChatID: String

        @Argument(help: "Message ID to forward")
        var messageID: Int

        func run() async throws {
            let api = try TelegramBot.makeAPI()
            let result = try await api.forwardMessage(chatId: chatID, fromChatId: fromChatID, messageId: messageID)
            try TelegramBot.printJSON(result)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a message")

        @Argument(help: "Chat ID")
        var chatID: String

        @Argument(help: "Message ID to delete")
        var messageID: Int

        func run() async throws {
            let api = try TelegramBot.makeAPI()
            try TelegramBot.printJSON(try await api.deleteMessage(chatId: chatID, messageId: messageID))
        }
    }
}
