import ArgumentParser
import Foundation
import TelegramAllLib

@main
struct TelegramAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "telegram-all",
        abstract: "Telegram personal account CLI (via TDLib)",
        subcommands: [AuthStatus.self, AuthPhone.self, AuthCode.self, AuthPassword.self, Me.self, Chats.self, History.self, Search.self, Send.self, Contacts.self]
    )
}

// MARK: - Shared

extension TelegramAll {
    static func makeClient() async throws -> TDLibClient {
        let env = ProcessInfo.processInfo.environment
        guard env["TELEGRAM_API_ID"] != nil, env["TELEGRAM_API_HASH"] != nil else {
            throw ValidationError(
                "TELEGRAM_API_ID and TELEGRAM_API_HASH environment variables not set.\n"
                + "Get them from https://my.telegram.org"
            )
        }
        return try await TDLibClient()
    }

    static func waitForAuth(_ client: TDLibClient) async throws {
        for _ in 0..<50 {
            if client.getAuthState() == .ready { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ValidationError("Authentication not ready (state: \(client.getAuthState().rawValue)). Run auth flow first.")
    }
}

// MARK: - Auth Command

extension TelegramAll {
    struct AuthStatus: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "auth-status", abstract: "Check authentication status")
        func run() async throws { try await AuthHelper.status() }
    }

    struct AuthPhone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "auth-phone", abstract: "Send phone number to begin authentication")
        @Argument(help: "Phone number with country code, e.g. +886912345678")
        var phone: String
        func run() async throws { try await AuthHelper.sendPhone(phone) }
    }

    struct AuthCode: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "auth-code", abstract: "Submit verification code")
        @Argument(help: "Verification code received in Telegram")
        var code: String
        func run() async throws { try await AuthHelper.sendCode(code) }
    }

    struct AuthPassword: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "auth-password", abstract: "Submit 2FA password")
        @Argument(help: "2FA password")
        var password: String
        func run() async throws { try await AuthHelper.sendPassword(password) }
    }
}

// MARK: - Commands

extension TelegramAll {
    struct Me: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get your profile info")

        func run() async throws {
            let client = try await TelegramAll.makeClient()
            try await TelegramAll.waitForAuth(client)
            print(try await client.getMe())
        }
    }

    struct Chats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recent conversations")

        @Option(name: .long, help: "Max chats to return (default 50)")
        var limit: Int = 50

        func run() async throws {
            let client = try await TelegramAll.makeClient()
            try await TelegramAll.waitForAuth(client)
            print(try await client.getChats(limit: limit))
        }
    }

    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read message history from a chat")

        @Argument(help: "Chat ID")
        var chatID: Int64

        @Option(name: .long, help: "Page size per TDLib fetch (default 50)")
        var limit: Int = 50

        @Option(name: .long, help: "Total cap for auto-pagination; omit for single page")
        var maxMessages: Int?

        @Option(name: .long, help: "Lower bound YYYY-MM-DD (inclusive)")
        var since: String?

        @Option(name: .long, help: "Upper bound YYYY-MM-DD (inclusive)")
        var until: String?

        @Option(name: .long, help: "If set, dump to this .md file instead of printing JSON")
        var dumpMarkdown: String?

        @Option(name: .long, help: "Label used for outgoing messages in markdown (default 我)")
        var selfLabel: String = "我"

        func run() async throws {
            let client = try await TelegramAll.makeClient()
            try await TelegramAll.waitForAuth(client)

            let sinceDate = try parseCLIDate(since, flagName: "--since")
            let untilDate = try parseCLIDate(until, flagName: "--until")

            if let path = dumpMarkdown {
                let exporter = MarkdownExporter(client: client)
                let summary = try await exporter.dumpChatToMarkdown(
                    chatId: chatID,
                    outputPath: path,
                    maxMessages: maxMessages ?? 5000,
                    sinceDate: sinceDate,
                    untilDate: untilDate,
                    selfLabel: selfLabel
                )
                print(summary)
                return
            }

            print(try await client.getChatHistory(
                chatId: chatID,
                limit: limit,
                fromMessageId: 0,
                maxMessages: maxMessages,
                sinceDate: sinceDate,
                untilDate: untilDate
            ))
        }

        private func parseCLIDate(_ s: String?, flagName: String) throws -> Foundation.Date? {
            guard let s = s, !s.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            guard let date = formatter.date(from: s) else {
                throw ValidationError("\(flagName) must be YYYY-MM-DD; got \(s)")
            }
            return date
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search messages in a chat")

        @Argument(help: "Chat ID")
        var chatID: Int64

        @Argument(help: "Search query")
        var query: String

        @Option(name: .long, help: "Max results (default 50)")
        var limit: Int = 50

        func run() async throws {
            let client = try await TelegramAll.makeClient()
            try await TelegramAll.waitForAuth(client)
            print(try await client.searchMessages(chatId: chatID, query: query, limit: limit))
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a text message")

        @Argument(help: "Chat ID")
        var chatID: Int64

        @Argument(help: "Message text")
        var text: String

        func run() async throws {
            let client = try await TelegramAll.makeClient()
            try await TelegramAll.waitForAuth(client)
            print(try await client.sendMessage(chatId: chatID, text: text))
        }
    }

    struct Contacts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your contacts")

        func run() async throws {
            let client = try await TelegramAll.makeClient()
            try await TelegramAll.waitForAuth(client)
            print(try await client.getContacts())
        }
    }
}
