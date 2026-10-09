import XCTest
@testable import TelegramAllLib

/// Task 3.6 (telegram-local-reader; PsychQuant/che-msg#58): an optional check
/// of the decoders against a real TDLib database directory.
///
/// Runs only when `CHE_TELEGRAM_READER_COMPARE_DIR` points to a copy of a TDLib
/// database directory (`td.binlog`, `db.sqlite` and, when present,
/// `db.sqlite-wal` and `db.sqlite-shm`). Every message's decoded `message_id`
/// and sender are compared with the table columns and its date is checked for
/// plausibility. Only counts and rates are printed; no text, name or title is
/// written or printed.
final class LocalReaderRealDataComparisonTests: XCTestCase {
    /// Telegram launched in August 2013.
    private let earliestPlausibleDate: Int32 = 1_375_315_200

    func testRealCacheDecodesConsistentlyWithItsColumns() throws {
        guard let dir = ProcessInfo.processInfo.environment["CHE_TELEGRAM_READER_COMPARE_DIR"], !dir.isEmpty else {
            throw XCTSkip("set CHE_TELEGRAM_READER_COMPARE_DIR to a copy of a TDLib database directory to run this check")
        }
        let cache = try TDLibCacheDatabase(directory: dir)
        let latestPlausibleDate = Int32(Date().timeIntervalSince1970) + 86_400

        var total = 0, prefixDecoded = 0, contentDecoded = 0, textDecoded = 0
        var idMismatches = 0, senderMismatches = 0, senderUncheckable = 0, implausibleDates = 0
        try cache.forEachRow("SELECT message_id, sender_user_id, data FROM messages") { row in
            total += 1
            let column = row.isNull(1) ? nil : row.int64(1)
            let record = TDLibMessageDecoder.decode(row.blob(2))
            guard let messageId = record.messageId, let date = record.date else { return }
            prefixDecoded += 1
            if messageId != row.int64(0) { idMismatches += 1 }
            if date < earliestPlausibleDate || date > latestPlausibleDate { implausibleDates += 1 }
            if record.kind != nil { contentDecoded += 1 }
            if record.kind == .text { textDecoded += 1 }
            // TDLib fills the column with sender_dialog_id when set, else sender_user_id.
            let decodedSender: Int64?
            if let dialog = record.senderDialogId {
                decodedSender = dialog
            } else if record.kind != nil || (column ?? 0) > 0 {
                decodedSender = record.senderUserId
            } else {
                senderUncheckable += 1   // stopped before sender_dialog_id, column names a chat
                return
            }
            if decodedSender != column { senderMismatches += 1 }
        }

        let records = try chatRecordRates(cache)
        func percent(_ part: Int) -> String { total == 0 ? "-" : String(format: "%.1f%%", 100.0 * Double(part) / Double(total)) }
        print("""
            telegram local reader comparison (counts only):
              messages \(total); prefix decoded \(prefixDecoded) (\(percent(prefixDecoded))); \
            content decoded \(contentDecoded) (\(percent(contentDecoded))); text messages \(textDecoded)
              message_id mismatches \(idMismatches); sender mismatches \(senderMismatches) \
            (\(senderUncheckable) not checkable); implausible dates \(implausibleDates)
              chat records decoded: \(records)
            """)
        XCTAssertEqual(idMismatches, 0)
        XCTAssertEqual(senderMismatches, 0)
        XCTAssertEqual(implausibleDates, 0)
    }

    /// "us 217/217, gr 8/8, …" over the records stored under exactly
    /// `<prefix><id>`; full-info records (`usf`, `grf`, `chf`) are not chats.
    private func chatRecordRates(_ cache: TDLibCacheDatabase) throws -> String {
        let decoders: [(String, ([UInt8]) -> Bool)] = [
            ("us", { (try? TDLibRecordDecoder.userTitle($0)) != nil }),
            ("gr", { (try? TDLibRecordDecoder.basicGroupTitle($0)) != nil }),
            ("ch", { (try? TDLibRecordDecoder.channel($0)) != nil }),
            ("sc", { (try? TDLibRecordDecoder.secretChatUserId($0)) != nil }),
        ]
        var parts: [String] = []
        for (prefix, decodes) in decoders {
            var found = 0, decoded = 0
            try cache.forEachRow("SELECT k, v FROM common WHERE CAST(k AS TEXT) LIKE '\(prefix)%'") { row in
                let id = String(decoding: row.blob(0), as: UTF8.self).dropFirst(prefix.count)
                guard Int64(id) != nil else { return }
                found += 1
                if decodes(row.blob(1)) { decoded += 1 }
            }
            parts.append("\(prefix) \(decoded)/\(found)")
        }
        return parts.joined(separator: ", ")
    }
}
