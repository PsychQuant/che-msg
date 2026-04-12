import Foundation

/// Lightweight Telegram Bot API client using URLSession.
/// All methods map directly to https://core.telegram.org/bots/api
public final class TelegramAPI {
    private let token: String
    private let baseURL: String
    private let session: URLSession

    public init(token: String) {
        self.token = token
        self.baseURL = "https://api.telegram.org/bot\(token)"
        self.session = URLSession.shared
    }

    // MARK: - Generic Request

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !params.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: params)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TelegramError.invalidJSON
        }

        guard let ok = json["ok"] as? Bool, ok else {
            let description = json["description"] as? String ?? "Unknown error"
            let errorCode = json["error_code"] as? Int ?? httpResponse.statusCode
            throw TelegramError.apiError(code: errorCode, description: description)
        }

        return json
    }

    // MARK: - Bot Info

    public func getMe() async throws -> [String: Any] {
        try await request("getMe")
    }

    // MARK: - Updates

    public func getUpdates(offset: Int? = nil, limit: Int? = nil, timeout: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let offset { params["offset"] = offset }
        if let limit { params["limit"] = limit }
        if let timeout { params["timeout"] = timeout }
        return try await request("getUpdates", params: params)
    }

    // MARK: - Sending Messages

    public func sendMessage(chatId: Any, text: String, parseMode: String? = nil, replyToMessageId: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "text": text]
        if let parseMode { params["parse_mode"] = parseMode }
        if let replyToMessageId { params["reply_to_message_id"] = replyToMessageId }
        return try await request("sendMessage", params: params)
    }

    public func forwardMessage(chatId: Any, fromChatId: Any, messageId: Int) async throws -> [String: Any] {
        try await request("forwardMessage", params: [
            "chat_id": chatId,
            "from_chat_id": fromChatId,
            "message_id": messageId
        ])
    }

    public func copyMessage(chatId: Any, fromChatId: Any, messageId: Int) async throws -> [String: Any] {
        try await request("copyMessage", params: [
            "chat_id": chatId,
            "from_chat_id": fromChatId,
            "message_id": messageId
        ])
    }

    // MARK: - Editing Messages

    public func editMessageText(chatId: Any? = nil, messageId: Int? = nil, text: String, parseMode: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["text": text]
        if let chatId { params["chat_id"] = chatId }
        if let messageId { params["message_id"] = messageId }
        if let parseMode { params["parse_mode"] = parseMode }
        return try await request("editMessageText", params: params)
    }

    public func deleteMessage(chatId: Any, messageId: Int) async throws -> [String: Any] {
        try await request("deleteMessage", params: [
            "chat_id": chatId,
            "message_id": messageId
        ])
    }

    // MARK: - Chat Management

    public func getChat(chatId: Any) async throws -> [String: Any] {
        try await request("getChat", params: ["chat_id": chatId])
    }

    public func getChatMemberCount(chatId: Any) async throws -> [String: Any] {
        try await request("getChatMemberCount", params: ["chat_id": chatId])
    }

    public func getChatMember(chatId: Any, userId: Int) async throws -> [String: Any] {
        try await request("getChatMember", params: ["chat_id": chatId, "user_id": userId])
    }

    public func getChatAdministrators(chatId: Any) async throws -> [String: Any] {
        try await request("getChatAdministrators", params: ["chat_id": chatId])
    }

    public func banChatMember(chatId: Any, userId: Int, untilDate: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "user_id": userId]
        if let untilDate { params["until_date"] = untilDate }
        return try await request("banChatMember", params: params)
    }

    public func unbanChatMember(chatId: Any, userId: Int, onlyIfBanned: Bool = true) async throws -> [String: Any] {
        try await request("unbanChatMember", params: [
            "chat_id": chatId,
            "user_id": userId,
            "only_if_banned": onlyIfBanned
        ])
    }

    public func restrictChatMember(chatId: Any, userId: Int, permissions: [String: Bool], untilDate: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "user_id": userId, "permissions": permissions]
        if let untilDate { params["until_date"] = untilDate }
        return try await request("restrictChatMember", params: params)
    }

    public func promoteChatMember(chatId: Any, userId: Int, rights: [String: Bool]) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "user_id": userId]
        for (key, value) in rights { params[key] = value }
        return try await request("promoteChatMember", params: params)
    }

    // MARK: - Pin/Unpin

    public func pinChatMessage(chatId: Any, messageId: Int, disableNotification: Bool = false) async throws -> [String: Any] {
        try await request("pinChatMessage", params: [
            "chat_id": chatId,
            "message_id": messageId,
            "disable_notification": disableNotification
        ])
    }

    public func unpinChatMessage(chatId: Any, messageId: Int? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId]
        if let messageId { params["message_id"] = messageId }
        return try await request("unpinChatMessage", params: params)
    }

    public func unpinAllChatMessages(chatId: Any) async throws -> [String: Any] {
        try await request("unpinAllChatMessages", params: ["chat_id": chatId])
    }

    // MARK: - Bot Commands

    public func setMyCommands(commands: [[String: String]], scope: [String: Any]? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["commands": commands]
        if let scope { params["scope"] = scope }
        return try await request("setMyCommands", params: params)
    }

    public func getMyCommands(scope: [String: Any]? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let scope { params["scope"] = scope }
        return try await request("getMyCommands", params: params)
    }

    public func deleteMyCommands(scope: [String: Any]? = nil) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let scope { params["scope"] = scope }
        return try await request("deleteMyCommands", params: params)
    }

    // MARK: - Sending Media (URL-based)

    public func sendPhoto(chatId: Any, photo: String, caption: String? = nil, parseMode: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "photo": photo]
        if let caption { params["caption"] = caption }
        if let parseMode { params["parse_mode"] = parseMode }
        return try await request("sendPhoto", params: params)
    }

    public func sendDocument(chatId: Any, document: String, caption: String? = nil, parseMode: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "document": document]
        if let caption { params["caption"] = caption }
        if let parseMode { params["parse_mode"] = parseMode }
        return try await request("sendDocument", params: params)
    }

    public func sendVideo(chatId: Any, video: String, caption: String? = nil, parseMode: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "video": video]
        if let caption { params["caption"] = caption }
        if let parseMode { params["parse_mode"] = parseMode }
        return try await request("sendVideo", params: params)
    }

    public func sendAudio(chatId: Any, audio: String, caption: String? = nil, parseMode: String? = nil) async throws -> [String: Any] {
        var params: [String: Any] = ["chat_id": chatId, "audio": audio]
        if let caption { params["caption"] = caption }
        if let parseMode { params["parse_mode"] = parseMode }
        return try await request("sendAudio", params: params)
    }

    public func sendLocation(chatId: Any, latitude: Double, longitude: Double) async throws -> [String: Any] {
        try await request("sendLocation", params: [
            "chat_id": chatId,
            "latitude": latitude,
            "longitude": longitude
        ])
    }

    public func sendPoll(chatId: Any, question: String, options: [[String: String]], isAnonymous: Bool = true, type: String = "regular") async throws -> [String: Any] {
        try await request("sendPoll", params: [
            "chat_id": chatId,
            "question": question,
            "options": options,
            "is_anonymous": isAnonymous,
            "type": type
        ])
    }

    // MARK: - Stickers

    public func sendSticker(chatId: Any, sticker: String) async throws -> [String: Any] {
        try await request("sendSticker", params: ["chat_id": chatId, "sticker": sticker])
    }

    // MARK: - Leave Chat

    public func leaveChat(chatId: Any) async throws -> [String: Any] {
        try await request("leaveChat", params: ["chat_id": chatId])
    }

    // MARK: - Set Chat Title/Description/Photo

    public func setChatTitle(chatId: Any, title: String) async throws -> [String: Any] {
        try await request("setChatTitle", params: ["chat_id": chatId, "title": title])
    }

    public func setChatDescription(chatId: Any, description: String) async throws -> [String: Any] {
        try await request("setChatDescription", params: ["chat_id": chatId, "description": description])
    }
}

// MARK: - Errors

public enum TelegramError: LocalizedError {
    case invalidResponse
    case invalidJSON
    case apiError(code: Int, description: String)
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid HTTP response"
        case .invalidJSON: return "Invalid JSON response"
        case .apiError(let code, let desc): return "Telegram API error \(code): \(desc)"
        case .missingToken: return "TELEGRAM_BOT_TOKEN environment variable not set"
        }
    }
}
