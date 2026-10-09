/// Messages from the TDLib cache (`messages` table).
extension TDLibCacheDatabase {
    /// Calls `body` with the cached messages of `chatId` whose id is at most
    /// `maxMessageId`, newest first, until `body` returns false. Including the
    /// message `maxMessageId` itself matches TDLib's `getChatHistory`, whose
    /// history starts at the newest message not above `from_message_id`
    /// (`OrderedMessages::get_history`).
    func forEachMessage(chatId: Int64, maxMessageId: Int64 = .max,
                        _ body: (LocalMessage) throws -> Bool) throws {
        let sql = "SELECT message_id, sender_user_id, data FROM messages "
            + "WHERE dialog_id = ?1 AND message_id <= ?2 ORDER BY message_id DESC"
        try forEachRow(sql, [.int(chatId), .int(maxMessageId)], until: { row in
            let message = TDLibMessageDecoder.message(chatId: chatId, messageId: row.int64(0),
                                                      senderColumn: row.isNull(1) ? nil : row.int64(1),
                                                      data: row.blob(2))
            return try body(message)
        })
    }

    /// The newest cached message of `chatId`, decodable or not.
    func newestMessage(chatId: Int64) throws -> LocalMessage? {
        var newest: LocalMessage?
        try forEachMessage(chatId: chatId) { newest = $0; return false }
        return newest
    }

    /// The date of the newest cached message of `chatId` whose date could be
    /// decoded.
    func freshness(chatId: Int64) throws -> LocalTDLibReader.ChatFreshness {
        var sawMessage = false
        var newestDate: Int32?
        try forEachMessage(chatId: chatId) { message in
            sawMessage = true
            newestDate = message.date
            return message.date == nil
        }
        if let newestDate { return .init(chatId: chatId, newest: .date(newestDate)) }
        return .init(chatId: chatId, newest: sawMessage ? .undated : .noMessages)
    }
}
