import Foundation
import SlackWebLib

/// Which messages one archive call lists, writes and asks replies for
/// (spec: slack-chat-archive, "Incremental archive and manifest" and
/// "Thread replies and lookback"; design: thread 回覆以回顧窗口補抓).
///
/// - Written: top-level messages after the `newest_ts` of the recorded
///   range this run continues, else after `after_ts`, else from
///   `since_date` on, else after the manifest's `newest_ts` (the bookmark),
///   else all.
/// - Listed: from the lower bound of the written ones, or from the start of
///   the lookback window when the manifest has a bookmark and the window
///   starts earlier. Slack has no request for "threads with new replies",
///   so the parents already archived inside the window are listed again
///   only to read their `latest_reply`; they are not written again.
/// - Replies fetched: for every parent written, and for every parent listed
///   but not written that `needsReplies` accepts.
/// - Continued: when the manifest records an unfinished walk for this kind
///   of call (its `continuation` without `after_ts` and `since_date`, its
///   `range`'s with the same lower bound), only the history below that
///   walk's `below_ts` is listed (sent as `latest`), down to the same lower
///   bound; messages newer than its `top_ts` wait for the next run.
struct ArchiveScope {
    let request: ArchiveRequest
    /// The manifest's `newest_ts`, or nil without a manifest.
    let bookmark: String?
    /// The manifest's `range` when this call gives the same lower bound
    /// (`oldest_ts` equal to `request.oldest`), so this run continues it;
    /// nil otherwise, and always without `after_ts` and `since_date`.
    let range: ArchiveManifest.ExplicitRange?
    /// The unfinished walk this run continues: the manifest's
    /// `continuation` without `after_ts` and `since_date`, else `range`'s.
    let continuation: ArchiveManifest.Continuation?
    /// The first second of the lookback window: `thread_lookback_days` days
    /// of 86400 seconds before the call's start; nil for a window of 0 days.
    let windowStart: Int64?

    init(request: ArchiveRequest, manifest: ArchiveManifest?, now: Date) {
        self.request = request
        bookmark = manifest?.newest_ts
        if let oldest = request.oldest {
            range = manifest?.range.flatMap { $0.oldest_ts == oldest ? $0 : nil }
            continuation = range?.continuation
        } else {
            range = nil
            continuation = manifest?.continuation
        }
        windowStart = request.threadLookbackDays > 0
            ? max(0, Int64(now.timeIntervalSince1970) - Int64(request.threadLookbackDays) * 86_400)
            : nil
    }

    /// The ts the written messages are newer than (see `isWritten`), or nil
    /// for the whole history.
    var bound: String? { range?.newest_ts ?? request.oldest ?? bookmark }

    /// Whether a listed top-level message is written. Slack already applies
    /// `oldest`; this keeps out a message at the bound itself and the older
    /// ones listed only for the lookback window.
    func isWritten(_ ts: String) -> Bool {
        if range?.newest_ts == nil, let since = request.sinceSeconds {
            return (SlackDayFile.seconds(ofTS: ts) ?? 0) >= since
        }
        guard let bound else { return true }
        return SlackDayFile.precedes(bound, ts)
    }

    /// The `oldest` sent to `conversations.history` (nil: the whole
    /// history). Listing the window costs one more history page per 200
    /// top-level messages in it that are older than the bound, about 3 s for
    /// 1500 messages at the default 350 ms pacing, counted in the same page
    /// limit. Without a bookmark nothing below the bound was archived, so
    /// there is nothing to check again and the bound is used as it is.
    var listOldest: String? {
        guard let bound, bookmark != nil, let windowStart else { return bound }
        let start = String(windowStart)
        return SlackDayFile.precedes(start, bound) ? start : bound
    }

    /// The `latest` sent to `conversations.history` (exclusive, Slack's
    /// default): the continued walk's `below_ts`, or nil.
    var listLatest: String? { continuation?.below_ts }

    /// True for a parent ts inside the lookback window.
    func isInWindow(_ ts: String) -> Bool {
        guard let windowStart, let seconds = SlackDayFile.seconds(ofTS: ts) else { return false }
        return seconds >= windowStart
    }

    /// A message that starts a thread; one Slack says has no replies is not
    /// asked about.
    static func isThreadParent(_ message: SlackMessage) -> Bool {
        message.threadTS == message.ts && message.replyCount != 0
    }

    /// Whether a parent listed but not written gets its replies fetched: it
    /// was archived before (at or below the bookmark), its ts is inside the
    /// lookback window, and Slack's `latest_reply` is newer than the reply
    /// ts the manifest records for it, or none is recorded (its first reply
    /// came after it was archived). A parent without a well-formed
    /// `latest_reply` is not asked about.
    func needsReplies(_ message: SlackMessage, recorded: String?) -> Bool {
        guard let bookmark, !SlackDayFile.precedes(bookmark, message.ts), Self.isThreadParent(message),
              isInWindow(message.ts), let latest = message.latestReply, SlackDayFile.seconds(ofTS: latest) != nil
        else { return false }
        guard let recorded else { return true }
        return SlackDayFile.precedes(recorded, latest)
    }

    /// The later of two ts, either of which may be absent.
    static func newer(_ a: String?, _ b: String?) -> String? {
        guard let a else { return b }
        guard let b else { return a }
        return SlackDayFile.precedes(a, b) ? b : a
    }

    /// The earlier of two ts, either of which may be absent.
    static func older(_ a: String?, _ b: String?) -> String? {
        guard let a else { return b }
        guard let b else { return a }
        return SlackDayFile.precedes(a, b) ? a : b
    }
}
