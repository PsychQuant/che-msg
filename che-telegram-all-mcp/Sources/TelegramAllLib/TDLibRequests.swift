import Foundation
import TDLibKit

/// Runs one TDLibKit request, turning TDLibKit's own error into `TDError.tdlibError` with
/// TDLib's code and message (PsychQuant/che-msg#71). Every request outside the four
/// authentication steps goes through it (`TDLibRequestTests` reads the sources): without it
/// the error reached the server and the CLI as "TDLibKit.Error error 1", and the server,
/// which does not depend on TDLibKit, cannot catch it. The archiver reads rate limits
/// (`429 "Too Many Requests: retry after <n>"`) from it (#69).
///
/// A 406 message must not be shown, so it is dropped; unlike an authentication step
/// (`mapTDLibError`) the request still fails, since its caller needs a result it did not
/// get. Other errors pass through unchanged.
internal func tdlibCall<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as TDLibKit.Error {
        throw TDLibClient.TDError.tdlibError(code: error.code, message: error.code == 406 ? "" : error.message)
    }
}

/// What a TDLib chat id can be created as, by TDLib's id ranges (td/telegram/DialogId.cpp);
/// nil for secret chats and ids TDLib does not use, which no chat can be created from.
internal enum TDLibChatID: Equatable {
    case user(Int64)
    case basicGroup(Int64)
    case supergroup(Int64)

    private static let maxUserId: Int64 = (1 << 40) - 1
    private static let maxBasicGroupId: Int64 = 999_999_999_999
    private static let zeroChannelId: Int64 = -1_000_000_000_000
    private static let maxChannelId: Int64 = 1_000_000_000_000 - (1 << 31)

    // Compared without negating `chatId`: `-Int64.min` traps and would end the server process.
    init?(_ chatId: Int64) {
        if (1...Self.maxUserId).contains(chatId) {
            self = .user(chatId)
        } else if (-Self.maxBasicGroupId ... -1).contains(chatId) {
            self = .basicGroup(-chatId)
        } else if (Self.zeroChannelId - Self.maxChannelId ... Self.zeroChannelId - 1).contains(chatId) {
            self = .supergroup(Self.zeroChannelId - chatId)
        } else {
            return nil
        }
    }
}

/// Makes a chat known to TDLib before a request on it (PsychQuant/che-msg#71; the archive's
/// since #69). `getChat` answers for chats TDLib has seen (its chat database keeps them), but
/// a new login has seen few, so on a 400 the chat is created from its id. When it cannot be
/// (an id no chat can be created from, or a 400 from the create request), the `getChat`
/// error is reported as `unknownChat`: the caller asked about the chat, and the create
/// request's error ("Supergroup not found") would name the wrong thing. Any other error,
/// such as a rate limit or a closed session, is thrown as it is, and after one from
/// `getChat` nothing is created.
///
/// The two requests are passed in, so this is tested without TDLib (`UnseenChatTests`).
internal func loadChat<Found>(_ chatId: Int64,
                              get: () async throws -> Found,
                              create: (TDLibChatID) async throws -> Found) async throws -> Found {
    let message: String
    do {
        return try await get()
    } catch TDLibClient.TDError.tdlibError(code: 400, message: let notFound) {
        message = notFound
    }
    let unknown = TDLibClient.TDError.unknownChat(chatId: chatId, code: 400, message: message)
    guard let kind = TDLibChatID(chatId) else { throw unknown }
    do {
        return try await create(kind)
    } catch TDLibClient.TDError.tdlibError(code: 400, message: _) {
        throw unknown
    }
}
