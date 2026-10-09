import Foundation

/// Decodes `messages.data`, the log event serialization of TDLib 1.8.60's
/// `MessagesManager::Message` (`Message::parse`, `parse_message_content`).
///
/// The fixed prefix (flag words, `message_id`, `sender_user_id`, `date`) is read
/// first and checked against the `message_id` column. A version newer than
/// 1.8.60, a flag bit 1.8.60 does not define, or a disagreeing message id leaves
/// only the table columns. After the prefix, the optional fields are skipped in
/// `Message::parse` order up to the content, whose type and, for text messages,
/// text are read. Fields the reader does not support (forward info, channel
/// comment info, restriction reasons, thread drafts) stop decoding where they
/// start: the message keeps its prefix fields and its type is `unknown`.
///
/// The sender comes from the `sender_user_id` column, which TDLib fills with
/// `get_message_sender()`: the sender chat's dialog id, else the sender user's id.
enum TDLibMessageDecoder {
    private struct Stop: Error {}

    static let addMessageTextFlags: Int32 = 49
    /// `MessageContentType::StarGiftPurchaseOfferDeclined`, the last content
    /// type in TDLib 1.8.60.
    static let newestContentType: Int32 = 85

    static func message(chatId: Int64, messageId: Int64, senderColumn: Int64?, data: [UInt8]) -> LocalMessage {
        let sender = senderColumn.flatMap(sender(fromColumn:))
        let record = decode(data)
        guard record.messageId == messageId else {
            return LocalMessage(id: messageId, chatId: chatId, date: nil, sender: sender,
                                isOutgoing: nil, type: .unknown, text: nil)
        }
        return LocalMessage(id: messageId, chatId: chatId, date: record.date, sender: sender,
                            isOutgoing: record.isOutgoing, type: record.kind ?? .unknown, text: record.text)
    }

    /// What decoding `messages.data` reached; a field is nil when decoding
    /// stopped before it or the record does not have it.
    struct Record: Equatable {
        var messageId: Int64?
        var date: Int32?
        var isOutgoing: Bool?
        /// `sender_user_id` from the prefix.
        var senderUserId: Int64?
        /// `sender_dialog_id`, when decoding reached it.
        var senderDialogId: Int64?
        /// Nil when decoding stopped before the content.
        var kind: LocalMessage.Kind?
        var text: String?
    }

    /// Decodes as far as the data allows. A record whose prefix cannot be read
    /// comes back empty.
    static func decode(_ data: [UInt8]) -> Record {
        var reader = TLReader(data)
        guard let prefix = try? readPrefix(&reader) else { return Record() }
        var record = Record(messageId: prefix.messageId, date: prefix.date, isOutgoing: prefix.isOutgoing,
                            senderUserId: prefix.senderUserId)
        try? readContent(&reader, after: prefix, into: &record)
        return record
    }

    static func sender(fromColumn value: Int64) -> LocalMessage.Sender? {
        if value > 0 { return .user(value) }
        if value < 0 { return .chat(value) }
        return nil
    }

    private struct Prefix {
        let version: Int32
        let flags: [UInt32]
        let messageId: Int64
        let senderUserId: Int64?
        let date: Int32
        var isOutgoing: Bool { isSet(flags[0], 1) }
    }

    /// The bits each of the four flag words defines in TDLib 1.8.60; bit 29 of
    /// the first three announces the next word.
    private static let definedBits: [UInt32] = [30, 30, 30, 4]

    private static func readPrefix(_ r: inout TLReader) throws -> Prefix {
        let version = try r.int32()
        guard (1...TDLibRecordDecoder.newestVersion).contains(version) else { throw Stop() }
        var words = [try r.uint32()]
        while words.count < 4, isSet(words[words.count - 1], 29) {
            words.append(try r.uint32())
        }
        words += [UInt32](repeating: 0, count: 4 - words.count)
        for (word, bits) in zip(words, definedBits) where word >> bits != 0 {
            throw Stop()
        }
        let messageId = try r.int64()
        let senderUserId = try isSet(words[0], 10) ? readUserId(&r, version: version) : nil
        let date = try r.int32()
        return Prefix(version: version, flags: words, messageId: messageId, senderUserId: senderUserId, date: date)
    }

    private static func readContent(_ r: inout TLReader, after p: Prefix, into record: inout Record) throws {
        let (f1, f2, f3) = (p.flags[0], p.flags[1], p.flags[2])
        if isSet(f1, 11) { _ = try r.int32() }                    // edit_date
        if isSet(f1, 28) { _ = try r.int32() }                    // send_date
        if isSet(f1, 12) { _ = try r.int64() }                    // random_id
        if isSet(f3, 12) || isSet(f1, 13) { throw Stop() }        // forward_info, legacy forward fields
        if isSet(f2, 7) { _ = try r.int64(); _ = try r.int64() }  // real_forward_from dialog and message
        if isSet(f1, 14) { _ = try r.int64() }                    // legacy reply_to_message_id
        if isSet(f1, 15) { _ = try r.int64() }                    // reply_to_random_id
        if isSet(f1, 16) { _ = try readUserId(&r, version: p.version) }   // via_bot_user_id
        if isSet(f1, 17) { _ = try r.int32() }                    // view_count
        if isSet(f2, 14) { _ = try r.int32() }                    // forward_count
        if isSet(f2, 15) { throw Stop() }                         // reply_info
        if isSet(f1, 19) { _ = try r.int32(); try skipTime(&r) }  // ttl, ttl_expires_at
        if isSet(f2, 4) {                                         // send_error_code, message, try_resend_at
            let code = try r.int32()
            _ = try r.string()
            if code == 429 { try skipTime(&r) }
        }
        if isSet(f1, 20) { _ = try r.string() }                   // author_signature
        if isSet(f1, 24) { _ = try r.int64() }                    // media_album_id
        if isSet(f2, 0) { _ = try r.int32() }                     // notification_id
        if isSet(f2, 8) { _ = try r.int32() }                     // legacy_layer
        if isSet(f2, 10) { throw Stop() }                         // restriction_reasons
        if isSet(f2, 16) { record.senderDialogId = try r.int64() }   // sender_dialog_id
        if isSet(f2, 17) { _ = try r.int64() }                    // legacy_reply_in_dialog_id
        if isSet(f2, 18) { _ = try r.int64() }                    // top_thread_message_id
        if isSet(f2, 19) { throw Stop() }                         // thread_draft_message
        if isSet(f2, 20) {                                        // local_thread_message_ids
            let count = try r.int32()
            guard count >= 0, Int(count) * 8 <= r.remaining else { throw Stop() }
            for _ in 0..<count { _ = try r.int64() }
        }
        if isSet(f2, 21) { _ = try r.int64() }                    // linked_top_thread_message_id
        if isSet(f2, 23) { _ = try r.int32() }                    // interaction_info_update_date
        if isSet(f2, 24) { _ = try r.string() }                   // send_emoji

        guard let kind = kind(forContentType: try r.int32()) else { throw Stop() }
        guard kind == .text else { record.kind = kind; return }
        if p.version >= addMessageTextFlags { _ = try r.uint32() }
        guard let text = String(bytes: try r.string(), encoding: .utf8) else { throw Stop() }
        record.kind = .text
        record.text = text
    }

    /// The TDLib-mode `type` name for a `MessageContentType` value (the names
    /// `TDLibClient.messageToDict` uses; live locations are `messageLocation`
    /// in the TDLib API). Nil for a value TDLib 1.8.60 does not define.
    static func kind(forContentType type: Int32) -> LocalMessage.Kind? {
        switch type {
        case 0: return .text
        case 1: return .animation
        case 3: return .document
        case 4: return .photo
        case 5: return .sticker
        case 6: return .video
        case 7: return .voiceNote
        case 9, 35: return .location
        case 31: return .videoNote
        case 40: return .poll
        case 0...newestContentType: return .other
        default: return nil
        }
    }

    /// `UserId` is an int32 before `Support64BitIds`.
    private static func readUserId(_ r: inout TLReader, version: Int32) throws -> Int64 {
        try version >= TDLibRecordDecoder.support64BitIds ? r.int64() : Int64(r.int32())
    }

    /// `parse_time`: the time left, then the server time unless the time left
    /// is below -0.1.
    private static func skipTime(_ r: inout TLReader) throws {
        let timeLeft = try r.double()
        if !(timeLeft < -0.1) { _ = try r.double() }
    }

    private static func isSet(_ word: UInt32, _ bit: UInt32) -> Bool { word & (1 << bit) != 0 }
}
