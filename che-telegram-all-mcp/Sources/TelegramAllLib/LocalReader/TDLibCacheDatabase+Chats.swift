/// Chats and user names from the TDLib cache (`dialogs` table and the
/// `us`/`gr`/`ch`/`sc` records in `common`).
extension TDLibCacheDatabase {
    /// Chats in the order TDLib lists them: `dialog_order` descending, then
    /// `dialog_id` descending (`DialogDbImpl::get_dialogs`). With
    /// `mainListOnly`, only the main chat list (folder 0, positive order);
    /// otherwise every chat the cache knows, archived and unlisted included.
    /// A chat whose record is missing or undecodable is `unknown` with no title.
    func chats(mainListOnly: Bool) throws -> [LocalChat] {
        let filter = mainListOnly ? "WHERE folder_id = 0 AND dialog_order > 0 " : ""
        var ids: [Int64] = []
        try forEachRow("SELECT dialog_id FROM dialogs \(filter)ORDER BY dialog_order DESC, dialog_id DESC") {
            ids.append($0.int64(0))
        }
        return try ids.map { try chat(id: $0) }
    }

    func chat(id: Int64) throws -> LocalChat {
        let kind = DialogKind(dialogId: id)
        guard let key = kind.recordKey, let record = try commonRecord(key) else {
            return LocalChat(id: id, title: nil, type: .unknown)
        }
        switch kind {
        case .user:
            if let title = try? TDLibRecordDecoder.userTitle(record) {
                return LocalChat(id: id, title: title, type: .privateChat)
            }
        case .basicGroup:
            if let title = try? TDLibRecordDecoder.basicGroupTitle(record) {
                return LocalChat(id: id, title: title, type: .basicGroup)
            }
        case .channel:
            if let channel = try? TDLibRecordDecoder.channel(record) {
                return LocalChat(id: id, title: channel.title, type: channel.isMegagroup ? .supergroup : .channel)
            }
        case .secretChat:
            if let userId = try? TDLibRecordDecoder.secretChatUserId(record) {
                return LocalChat(id: id, title: try userTitle(id: userId), type: .secret)
            }
        case .none:
            break
        }
        return LocalChat(id: id, title: nil, type: .unknown)
    }

    /// The user's name as TDLib titles their private chat, or nil when the
    /// record is missing or undecodable.
    func userTitle(id: Int64) throws -> String? {
        guard let record = try commonRecord("us\(id)") else { return nil }
        return try? TDLibRecordDecoder.userTitle(record)
    }

    /// The user's first and last name, or nil when the record is missing or
    /// undecodable.
    func userName(id: Int64) throws -> (first: String, last: String)? {
        guard let record = try commonRecord("us\(id)") else { return nil }
        return try? TDLibRecordDecoder.userName(record)
    }

    /// The value stored under `key` in `common`. TDLib's SqliteKeyValue binds
    /// both key and value as BLOBs, so the key is matched as a BLOB.
    func commonRecord(_ key: String) throws -> [UInt8]? {
        var value: [UInt8]?
        try forEachRow("SELECT v FROM common WHERE k = ?1", [.blob(Array(key.utf8))]) { value = $0.blob(0) }
        return value
    }
}
