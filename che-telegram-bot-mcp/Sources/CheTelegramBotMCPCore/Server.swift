import Foundation
import MCP

public final class CheTelegramBotMCPServer {
    private let server: Server
    private let transport: StdioTransport
    private let tools: [Tool]
    private let api: TelegramAPI

    public init() async throws {
        guard let token = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] else {
            throw TelegramError.missingToken
        }

        api = TelegramAPI(token: token)
        tools = Self.defineTools()

        server = Server(
            name: "che-telegram-bot-mcp",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )

        transport = StdioTransport()
        await registerHandlers()
    }

    public func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    private static func defineTools() -> [Tool] {
        [
            // Bot Info
            tool("get_me",
                 description: "Get basic information about the bot",
                 properties: [:], required: []),

            // Messages
            tool("send_message",
                 description: "Send a text message to a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID or @channel_username"),
                    "text": prop("string", "Message text"),
                    "parse_mode": prop("string", "Optional: Markdown, MarkdownV2, or HTML"),
                    "reply_to_message_id": prop("integer", "Optional: ID of the message to reply to"),
                 ],
                 required: ["chat_id", "text"]),

            tool("forward_message",
                 description: "Forward a message from one chat to another",
                 properties: [
                    "chat_id": prop("string", "Target chat ID"),
                    "from_chat_id": prop("string", "Source chat ID"),
                    "message_id": prop("integer", "Message ID to forward"),
                 ],
                 required: ["chat_id", "from_chat_id", "message_id"]),

            tool("copy_message",
                 description: "Copy a message (without forward header) from one chat to another",
                 properties: [
                    "chat_id": prop("string", "Target chat ID"),
                    "from_chat_id": prop("string", "Source chat ID"),
                    "message_id": prop("integer", "Message ID to copy"),
                 ],
                 required: ["chat_id", "from_chat_id", "message_id"]),

            tool("edit_message_text",
                 description: "Edit a previously sent message",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "message_id": prop("integer", "Message ID to edit"),
                    "text": prop("string", "New text"),
                    "parse_mode": prop("string", "Optional: Markdown, MarkdownV2, or HTML"),
                 ],
                 required: ["chat_id", "message_id", "text"]),

            tool("delete_message",
                 description: "Delete a message",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "message_id": prop("integer", "Message ID to delete"),
                 ],
                 required: ["chat_id", "message_id"]),

            // Updates
            tool("get_updates",
                 description: "Get incoming updates (messages, callbacks, etc.) via long polling",
                 properties: [
                    "offset": prop("integer", "Identifier of the first update to be returned"),
                    "limit": prop("integer", "Max number of updates (1-100, default 100)"),
                    "timeout": prop("integer", "Timeout in seconds for long polling (default 0)"),
                 ],
                 required: []),

            // Chat Info
            tool("get_chat",
                 description: "Get up-to-date information about a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID or @channel_username"),
                 ],
                 required: ["chat_id"]),

            tool("get_chat_member_count",
                 description: "Get the number of members in a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                 ],
                 required: ["chat_id"]),

            tool("get_chat_member",
                 description: "Get information about a member of a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "user_id": prop("integer", "User ID"),
                 ],
                 required: ["chat_id", "user_id"]),

            tool("get_chat_administrators",
                 description: "Get a list of administrators in a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                 ],
                 required: ["chat_id"]),

            // Member Management
            tool("ban_chat_member",
                 description: "Ban a user in a group/supergroup/channel",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "user_id": prop("integer", "User ID to ban"),
                    "until_date": prop("integer", "Optional: Unix timestamp when the ban will be lifted"),
                 ],
                 required: ["chat_id", "user_id"]),

            tool("unban_chat_member",
                 description: "Unban a previously banned user",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "user_id": prop("integer", "User ID to unban"),
                 ],
                 required: ["chat_id", "user_id"]),

            tool("restrict_chat_member",
                 description: "Restrict a user in a supergroup (set permissions)",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "user_id": prop("integer", "User ID to restrict"),
                    "can_send_messages": prop("boolean", "Allow sending text messages"),
                    "can_send_media_messages": prop("boolean", "Allow sending media"),
                    "can_send_polls": prop("boolean", "Allow sending polls"),
                    "can_send_other_messages": prop("boolean", "Allow sending stickers, GIFs, etc."),
                    "can_add_web_page_previews": prop("boolean", "Allow adding link previews"),
                    "can_change_info": prop("boolean", "Allow changing chat info"),
                    "can_invite_users": prop("boolean", "Allow inviting users"),
                    "can_pin_messages": prop("boolean", "Allow pinning messages"),
                    "until_date": prop("integer", "Optional: Unix timestamp when restrictions will be lifted"),
                 ],
                 required: ["chat_id", "user_id"]),

            tool("promote_chat_member",
                 description: "Promote or demote a user in a supergroup/channel",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "user_id": prop("integer", "User ID to promote"),
                    "can_manage_chat": prop("boolean", "Allow managing the chat"),
                    "can_post_messages": prop("boolean", "Allow posting in channels"),
                    "can_edit_messages": prop("boolean", "Allow editing messages of others"),
                    "can_delete_messages": prop("boolean", "Allow deleting messages"),
                    "can_manage_video_chats": prop("boolean", "Allow managing video chats"),
                    "can_restrict_members": prop("boolean", "Allow restricting members"),
                    "can_promote_members": prop("boolean", "Allow promoting members"),
                    "can_change_info": prop("boolean", "Allow changing chat info"),
                    "can_invite_users": prop("boolean", "Allow inviting users"),
                    "can_pin_messages": prop("boolean", "Allow pinning messages"),
                 ],
                 required: ["chat_id", "user_id"]),

            // Pin/Unpin
            tool("pin_chat_message",
                 description: "Pin a message in a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "message_id": prop("integer", "Message ID to pin"),
                    "disable_notification": prop("boolean", "Pass true to pin silently"),
                 ],
                 required: ["chat_id", "message_id"]),

            tool("unpin_chat_message",
                 description: "Unpin a message in a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "message_id": prop("integer", "Optional: specific message to unpin"),
                 ],
                 required: ["chat_id"]),

            tool("unpin_all_chat_messages",
                 description: "Unpin all pinned messages in a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                 ],
                 required: ["chat_id"]),

            // Media
            tool("send_photo",
                 description: "Send a photo by URL or file_id",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "photo": prop("string", "Photo URL or file_id"),
                    "caption": prop("string", "Optional: photo caption"),
                    "parse_mode": prop("string", "Optional: Markdown, MarkdownV2, or HTML"),
                 ],
                 required: ["chat_id", "photo"]),

            tool("send_document",
                 description: "Send a document by URL or file_id",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "document": prop("string", "Document URL or file_id"),
                    "caption": prop("string", "Optional: document caption"),
                    "parse_mode": prop("string", "Optional: Markdown, MarkdownV2, or HTML"),
                 ],
                 required: ["chat_id", "document"]),

            tool("send_video",
                 description: "Send a video by URL or file_id",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "video": prop("string", "Video URL or file_id"),
                    "caption": prop("string", "Optional: video caption"),
                    "parse_mode": prop("string", "Optional: Markdown, MarkdownV2, or HTML"),
                 ],
                 required: ["chat_id", "video"]),

            tool("send_audio",
                 description: "Send audio by URL or file_id",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "audio": prop("string", "Audio URL or file_id"),
                    "caption": prop("string", "Optional: audio caption"),
                    "parse_mode": prop("string", "Optional: Markdown, MarkdownV2, or HTML"),
                 ],
                 required: ["chat_id", "audio"]),

            tool("send_location",
                 description: "Send a location point on the map",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "latitude": prop("number", "Latitude"),
                    "longitude": prop("number", "Longitude"),
                 ],
                 required: ["chat_id", "latitude", "longitude"]),

            tool("send_poll",
                 description: "Send a poll. Pass options as a JSON array of strings, e.g. [\"Yes\", \"No\", \"Maybe\"]",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "question": prop("string", "Poll question (1-300 chars)"),
                    "options": arrayOfStringsProp("List of poll option texts, e.g. [\"Yes\", \"No\"]"),
                    "is_anonymous": prop("boolean", "Pass false for non-anonymous poll"),
                    "type": prop("string", "'regular' or 'quiz'"),
                 ],
                 required: ["chat_id", "question", "options"]),

            tool("send_sticker",
                 description: "Send a sticker by file_id or URL",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "sticker": prop("string", "Sticker file_id or URL"),
                 ],
                 required: ["chat_id", "sticker"]),

            // Bot Commands
            tool("set_my_commands",
                 description: "Set the bot's command list. Pass commands as JSON array, e.g. [{\"command\":\"start\",\"description\":\"Start the bot\"}]",
                 properties: [
                    "commands": arrayOfObjectsProp(
                        "List of bot commands",
                        itemProperties: [
                            "command": prop("string", "Command name without /"),
                            "description": prop("string", "Command description"),
                        ]
                    ),
                 ],
                 required: ["commands"]),

            tool("get_my_commands",
                 description: "Get the bot's current command list",
                 properties: [:], required: []),

            tool("delete_my_commands",
                 description: "Delete the bot's command list",
                 properties: [:], required: []),

            // Chat Settings
            tool("set_chat_title",
                 description: "Change the title of a chat (group/supergroup/channel)",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "title": prop("string", "New chat title (1-128 chars)"),
                 ],
                 required: ["chat_id", "title"]),

            tool("set_chat_description",
                 description: "Change the description of a chat",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                    "description": prop("string", "New chat description (0-255 chars)"),
                 ],
                 required: ["chat_id", "description"]),

            tool("leave_chat",
                 description: "Make the bot leave a group/supergroup/channel",
                 properties: [
                    "chat_id": prop("string", "Chat ID"),
                 ],
                 required: ["chat_id"]),
        ]
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await self.handleToolCall(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    // MARK: - Tool Call Dispatch

    private func handleToolCall(name: String, arguments args: [String: Value]) async -> CallTool.Result {
        do {
            let result: [String: Any]

            switch name {
            // Bot Info
            case "get_me":
                result = try await api.getMe()

            // Updates
            case "get_updates":
                result = try await api.getUpdates(
                    offset: args["offset"]?.intValue,
                    limit: args["limit"]?.intValue,
                    timeout: args["timeout"]?.intValue
                )

            // Messages
            case "send_message":
                result = try await api.sendMessage(
                    chatId: chatId(args),
                    text: args["text"]?.stringValue ?? "",
                    parseMode: args["parse_mode"]?.stringValue,
                    replyToMessageId: args["reply_to_message_id"]?.intValue
                )

            case "forward_message":
                guard let msgId = args["message_id"]?.intValue else {
                    return errorResult("message_id is required")
                }
                result = try await api.forwardMessage(
                    chatId: chatId(args),
                    fromChatId: args["from_chat_id"]?.stringValue ?? "",
                    messageId: msgId
                )

            case "copy_message":
                guard let msgId = args["message_id"]?.intValue else {
                    return errorResult("message_id is required")
                }
                result = try await api.copyMessage(
                    chatId: chatId(args),
                    fromChatId: args["from_chat_id"]?.stringValue ?? "",
                    messageId: msgId
                )

            case "edit_message_text":
                result = try await api.editMessageText(
                    chatId: chatId(args),
                    messageId: args["message_id"]?.intValue,
                    text: args["text"]?.stringValue ?? "",
                    parseMode: args["parse_mode"]?.stringValue
                )

            case "delete_message":
                guard let msgId = args["message_id"]?.intValue else {
                    return errorResult("message_id is required")
                }
                result = try await api.deleteMessage(
                    chatId: chatId(args),
                    messageId: msgId
                )

            // Chat Info
            case "get_chat":
                result = try await api.getChat(chatId: chatId(args))

            case "get_chat_member_count":
                result = try await api.getChatMemberCount(chatId: chatId(args))

            case "get_chat_member":
                guard let userId = args["user_id"]?.intValue else {
                    return errorResult("user_id is required")
                }
                result = try await api.getChatMember(chatId: chatId(args), userId: userId)

            case "get_chat_administrators":
                result = try await api.getChatAdministrators(chatId: chatId(args))

            // Member Management
            case "ban_chat_member":
                guard let userId = args["user_id"]?.intValue else {
                    return errorResult("user_id is required")
                }
                result = try await api.banChatMember(
                    chatId: chatId(args),
                    userId: userId,
                    untilDate: args["until_date"]?.intValue
                )

            case "unban_chat_member":
                guard let userId = args["user_id"]?.intValue else {
                    return errorResult("user_id is required")
                }
                result = try await api.unbanChatMember(chatId: chatId(args), userId: userId)

            case "restrict_chat_member":
                guard let userId = args["user_id"]?.intValue else {
                    return errorResult("user_id is required")
                }
                var permissions: [String: Bool] = [:]
                for key in ["can_send_messages", "can_send_media_messages", "can_send_polls",
                            "can_send_other_messages", "can_add_web_page_previews",
                            "can_change_info", "can_invite_users", "can_pin_messages"] {
                    if let val = args[key]?.boolValue { permissions[key] = val }
                }
                result = try await api.restrictChatMember(
                    chatId: chatId(args),
                    userId: userId,
                    permissions: permissions,
                    untilDate: args["until_date"]?.intValue
                )

            case "promote_chat_member":
                guard let userId = args["user_id"]?.intValue else {
                    return errorResult("user_id is required")
                }
                var rights: [String: Bool] = [:]
                for key in ["can_manage_chat", "can_post_messages", "can_edit_messages",
                            "can_delete_messages", "can_manage_video_chats", "can_restrict_members",
                            "can_promote_members", "can_change_info", "can_invite_users", "can_pin_messages"] {
                    if let val = args[key]?.boolValue { rights[key] = val }
                }
                result = try await api.promoteChatMember(
                    chatId: chatId(args),
                    userId: userId,
                    rights: rights
                )

            // Pin/Unpin
            case "pin_chat_message":
                guard let msgId = args["message_id"]?.intValue else {
                    return errorResult("message_id is required")
                }
                result = try await api.pinChatMessage(
                    chatId: chatId(args),
                    messageId: msgId,
                    disableNotification: args["disable_notification"]?.boolValue ?? false
                )

            case "unpin_chat_message":
                result = try await api.unpinChatMessage(
                    chatId: chatId(args),
                    messageId: args["message_id"]?.intValue
                )

            case "unpin_all_chat_messages":
                result = try await api.unpinAllChatMessages(chatId: chatId(args))

            // Media
            case "send_photo":
                result = try await api.sendPhoto(
                    chatId: chatId(args),
                    photo: args["photo"]?.stringValue ?? "",
                    caption: args["caption"]?.stringValue,
                    parseMode: args["parse_mode"]?.stringValue
                )

            case "send_document":
                result = try await api.sendDocument(
                    chatId: chatId(args),
                    document: args["document"]?.stringValue ?? "",
                    caption: args["caption"]?.stringValue,
                    parseMode: args["parse_mode"]?.stringValue
                )

            case "send_video":
                result = try await api.sendVideo(
                    chatId: chatId(args),
                    video: args["video"]?.stringValue ?? "",
                    caption: args["caption"]?.stringValue,
                    parseMode: args["parse_mode"]?.stringValue
                )

            case "send_audio":
                result = try await api.sendAudio(
                    chatId: chatId(args),
                    audio: args["audio"]?.stringValue ?? "",
                    caption: args["caption"]?.stringValue,
                    parseMode: args["parse_mode"]?.stringValue
                )

            case "send_location":
                guard let lat = args["latitude"]?.doubleValue, let lng = args["longitude"]?.doubleValue else {
                    return errorResult("latitude and longitude are required")
                }
                result = try await api.sendLocation(chatId: chatId(args), latitude: lat, longitude: lng)

            case "send_poll":
                let optionTexts: [String] = args["options"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let options = optionTexts.map { ["text": $0] }
                result = try await api.sendPoll(
                    chatId: chatId(args),
                    question: args["question"]?.stringValue ?? "",
                    options: options,
                    isAnonymous: args["is_anonymous"]?.boolValue ?? true,
                    type: args["type"]?.stringValue ?? "regular"
                )

            case "send_sticker":
                result = try await api.sendSticker(
                    chatId: chatId(args),
                    sticker: args["sticker"]?.stringValue ?? ""
                )

            // Bot Commands
            case "set_my_commands":
                var commands: [[String: String]] = []
                if let cmdArray = args["commands"]?.arrayValue {
                    for cmd in cmdArray {
                        if let obj = cmd.objectValue,
                           let command = obj["command"]?.stringValue,
                           let desc = obj["description"]?.stringValue {
                            commands.append(["command": command, "description": desc])
                        }
                    }
                }
                result = try await api.setMyCommands(commands: commands)

            case "get_my_commands":
                result = try await api.getMyCommands()

            case "delete_my_commands":
                result = try await api.deleteMyCommands()

            // Chat Settings
            case "set_chat_title":
                result = try await api.setChatTitle(
                    chatId: chatId(args),
                    title: args["title"]?.stringValue ?? ""
                )

            case "set_chat_description":
                result = try await api.setChatDescription(
                    chatId: chatId(args),
                    description: args["description"]?.stringValue ?? ""
                )

            case "leave_chat":
                result = try await api.leaveChat(chatId: chatId(args))

            default:
                return errorResult("Unknown tool: \(name)")
            }

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return CallTool.Result(content: [.text(jsonString)], isError: false)

        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func chatId(_ args: [String: Value]) -> String {
        if let s = args["chat_id"]?.stringValue { return s }
        if let n = args["chat_id"]?.intValue { return String(n) }
        return ""
    }

    private func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text("Error: \(message)")], isError: true)
    }

    // MARK: - Schema Builder Helpers

    private static func prop(_ type: String, _ description: String) -> Value {
        .object([
            "type": .string(type),
            "description": .string(description)
        ])
    }

    private static func arrayOfStringsProp(_ description: String) -> Value {
        let itemSchema: [String: Value] = ["type": .string("string")]
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(itemSchema)
        ])
    }

    private static func arrayOfObjectsProp(_ description: String, itemProperties: [String: Value]) -> Value {
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("object"),
                "properties": .object(itemProperties)
            ])
        ])
    }

    private static func tool(
        _ name: String,
        description: String,
        properties: [String: Value],
        required: [String]
    ) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) })
            ])
        )
    }
}
