import Foundation

/// Extract the Unix timestamp `date` field from a message dict and convert to Date.
///
/// Accepts any numeric representation (Int, Int64, Double) by bridging through NSNumber —
/// Foundation's `[String: Any]` dictionaries often round-trip integers through NSNumber,
/// which is `as? Int` compatible on one platform but not another. NSNumber is universal.
internal func messageDate(_ dict: [String: Any]) -> Date? {
    guard let value = dict["date"] else { return nil }
    if let n = value as? NSNumber {
        return Date(timeIntervalSince1970: n.doubleValue)
    }
    return nil
}

/// Filter messages by inclusive date range. Nil bounds are open.
///
/// A message is retained iff `since <= message.date <= until` where unspecified bounds
/// are treated as open. Messages without a parseable `date` field are retained.
internal func filterMessagesByDate(
    _ messages: [[String: Any]],
    since: Date?,
    until: Date?
) -> [[String: Any]] {
    if since == nil && until == nil { return messages }
    return messages.filter { msg in
        guard let date = messageDate(msg) else { return true }
        if let since = since, date < since { return false }
        if let until = until, date > until { return false }
        return true
    }
}

/// Returns true if the batch (newest → oldest order) contains any message older than `sinceDate`.
/// Used by pagination loops to decide early termination on the `sinceDate` boundary.
internal func batchCrossesSinceBoundary(
    _ batch: [[String: Any]],
    sinceDate: Date?
) -> Bool {
    guard let since = sinceDate else { return false }
    for msg in batch {
        guard let date = messageDate(msg) else { continue }
        if date < since { return true }
    }
    return false
}

/// Extract the lowest `id` value in the batch (used as `fromMessageId` for the next TDLib page).
/// Returns nil if the batch has no parseable id.
internal func lowestMessageId(_ messages: [[String: Any]]) -> Int64? {
    var minId: Int64?
    for msg in messages {
        let id: Int64?
        if let v = msg["id"] as? Int64 { id = v }
        else if let v = msg["id"] as? Int { id = Int64(v) }
        else { id = nil }
        guard let current = id else { continue }
        if let existing = minId { minId = min(existing, current) } else { minId = current }
    }
    return minId
}

/// Pagination helper: decide whether to request the next page and emit a trimmed accumulation.
///
/// - Returns: `(accumulated, shouldContinue, nextFromMessageId)` where:
///   - `accumulated`: messages accumulated so far (may be trimmed to `maxMessages`)
///   - `shouldContinue`: whether the caller should fetch another batch
///   - `nextFromMessageId`: the id to pass as `fromMessageId` on the next fetch (nil if stopping)
internal func accumulatePaginationBatch(
    current: [[String: Any]],
    newBatch: [[String: Any]],
    sinceDate: Date?,
    untilDate: Date?,
    maxMessages: Int
) -> (accumulated: [[String: Any]], shouldContinue: Bool, nextFromMessageId: Int64?) {
    // Filter this batch by date range before accumulating.
    let filtered = filterMessagesByDate(newBatch, since: sinceDate, until: untilDate)
    var accumulated = current + filtered

    // Trim to the max-message cap.
    if accumulated.count >= maxMessages {
        accumulated = Array(accumulated.prefix(maxMessages))
        return (accumulated, false, nil)
    }

    // TDLib returned an empty batch → conversation start reached.
    if newBatch.isEmpty {
        return (accumulated, false, nil)
    }

    // sinceDate boundary crossed by this batch → no older messages needed.
    if batchCrossesSinceBoundary(newBatch, sinceDate: sinceDate) {
        return (accumulated, false, nil)
    }

    // Continue paginating from the oldest (lowest id) message in the new batch.
    return (accumulated, true, lowestMessageId(newBatch))
}
