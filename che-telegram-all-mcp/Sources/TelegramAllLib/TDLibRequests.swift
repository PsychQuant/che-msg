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
/// nil for every other id. Secret chats are among them by choice: TDLib has `createSecretChat`
/// (by secret chat id), but this client opens TDLib with `useSecretChats: false`, and ids
/// outside the ranges name no chat at all.
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

/// TDLib's answer to a create request when it has no information about the user or group
/// (`MessagesManager::create_dialog`, td at cb863c16). TDLib's messages are "subject to future
/// changes"; if this one changes, the create error is reported as it is, without the hint.
let tdlibChatInfoNotFound = "Chat info not found"

/// Makes a chat known to TDLib before a request on it (PsychQuant/che-msg#71; the archive's
/// since #69). `getChat` answers for chats TDLib has loaded (its chat database keeps them),
/// but a new login has loaded few, and a 400 ("Chat not found") then means TDLib may still be
/// able to load the chat: it is created from its id with `force: false`, so TDLib asks the
/// server when it has not loaded the chat rather than making one up.
///
/// - `getChat`'s other errors (a rate limit, a closed session) are thrown as they are, and
///   nothing is created.
/// - An id no chat can be created from keeps `getChat`'s error, without a hint.
/// - A create request answered "Chat info not found" (TDLib has no information about the user
///   or group) is reported as `unknownChat` with `getChat`'s error, the one the caller asked
///   about, so the server adds a hint to call `get_chats`.
/// - Any other create error is thrown as it is: "Can't access the chat" (a private supergroup
///   or channel the account has left or is banned from), which `get_chats` cannot fix, a rate limit the archive waits out, a
///   closed session.
///
/// The requests are passed in, one per kind of id with TDLib's own arguments, so this is
/// tested without TDLib (`UnseenChatTests`).
internal func loadChat<Found>(
    _ chatId: Int64,
    get: () async throws -> Found,
    createPrivateChat: (_ force: Bool, _ userId: Int64) async throws -> Found,
    createBasicGroupChat: (_ basicGroupId: Int64, _ force: Bool) async throws -> Found,
    createSupergroupChat: (_ force: Bool, _ supergroupId: Int64) async throws -> Found
) async throws -> Found {
    let notFound: String
    do {
        return try await get()
    } catch TDLibClient.TDError.tdlibError(code: 400, message: let message) {
        notFound = message
    }
    guard let kind = TDLibChatID(chatId) else {
        throw TDLibClient.TDError.tdlibError(code: 400, message: notFound)
    }
    do {
        switch kind {
        case .user(let userId): return try await createPrivateChat(false, userId)
        case .basicGroup(let basicGroupId): return try await createBasicGroupChat(basicGroupId, false)
        case .supergroup(let supergroupId): return try await createSupergroupChat(false, supergroupId)
        }
    } catch TDLibClient.TDError.tdlibError(code: 400, message: tdlibChatInfoNotFound) {
        throw TDLibClient.TDError.unknownChat(chatId: chatId, code: 400, message: notFound)
    }
}
