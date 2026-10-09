/// A message as the local reader sees it.
struct LocalMessage: Equatable {
    enum Sender: Equatable {
        case user(Int64)
        case chat(Int64)
    }

    enum Kind: String {
        case text, photo, video, document, sticker, animation, location, poll, other, unknown
        case voiceNote = "voice_note"
        case videoNote = "video_note"
    }

    let id: Int64
    let chatId: Int64
    let date: Int32?
    let sender: Sender?
    let isOutgoing: Bool?
    let type: Kind
    let text: String?

    /// The TDLib-mode JSON object (`TDLibClient.messageToDict`); fields the
    /// reader could not determine are omitted.
    var dictionary: [String: Any] {
        var result: [String: Any] = ["id": id, "chat_id": chatId, "type": type.rawValue]
        if let date { result["date"] = date }
        switch sender {
        case .user(let userId): result["sender"] = ["type": "user", "user_id": userId]
        case .chat(let chatId): result["sender"] = ["type": "chat", "chat_id": chatId]
        case nil: break
        }
        if let isOutgoing { result["is_outgoing"] = isOutgoing }
        if let text { result["text"] = text }
        return result
    }
}
