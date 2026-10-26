import XCTest
@testable import TelegramAllLib

/// A chat TDLib has not loaded is loaded by its id before a tool's first request on it
/// (PsychQuant/che-msg#71). A new login has seen few chats, and `get_chat_history` on any
/// other answered "Chat not found"; only the archive created the chat from its id (#69).
///
/// `loadChat` takes `getChat` and the three create requests as closures, so the decision and
/// the request each kind of id gets are tested here without TDLib; `TDLibRequestTests` checks
/// that every method taking a chat id uses it and that the closures send those requests.
///
/// The errors follow TDLib (td/telegram at cb863c16): `getChat` answers 400 "Chat not found"
/// for a chat it has not loaded; `createPrivateChat` / `createBasicGroupChat` /
/// `createSupergroupChat` (`MessagesManager::create_dialog`) answer 400 "Chat info not found"
/// when TDLib has no information about the user or group, and 400 "Can't access the chat"
/// when it has some but may not read the chat (a private supergroup or channel the account
/// is not in; a basic group TDLib knows is always readable).
final class UnseenChatTests: XCTestCase {
    private typealias TDError = TDLibClient.TDError
    private let notFound = TDError.tdlibError(code: 400, message: "Chat not found")

    /// `loadChat` with create requests that record what they were asked and answer with
    /// `create` (given the request's description), "created" by default.
    private func load(_ chatId: Int64, get: () async throws -> String,
                      create: (String) async throws -> String = { _ in "created" }) async -> (Result<String, Error>, [String]) {
        var requests: [String] = []
        let result: Result<String, Error>
        do {
            result = .success(try await loadChat(
                chatId, get: get,
                createPrivateChat: { force, userId in
                    requests.append("createPrivateChat(force: \(force), userId: \(userId))")
                    return try await create(requests[requests.count - 1])
                },
                createBasicGroupChat: { basicGroupId, force in
                    requests.append("createBasicGroupChat(basicGroupId: \(basicGroupId), force: \(force))")
                    return try await create(requests[requests.count - 1])
                },
                createSupergroupChat: { force, supergroupId in
                    requests.append("createSupergroupChat(force: \(force), supergroupId: \(supergroupId))")
                    return try await create(requests[requests.count - 1])
                }))
        } catch {
            result = .failure(error)
        }
        return (result, requests)
    }

    private func error(_ result: Result<String, Error>) -> Error? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private func unknownChat(_ error: Error?) -> (chatId: Int64, code: Int, message: String)? {
        guard case TDError.unknownChat(let chatId, let code, let message)? = error else { return nil }
        return (chatId, code, message)
    }

    func testAKnownChatIsNotCreated() async {
        let (result, requests) = await load(123_456_789, get: { "known" })
        XCTAssertEqual(try? result.get(), "known")
        XCTAssertEqual(requests, [])
    }

    /// One create request, the one for the id's kind, with the id it names and `force: false`
    /// (with `force: true` TDLib makes up the chat without asking the server).
    func testEachKindOfIdGetsItsOwnCreateRequest() async {
        let cases: [(Int64, String)] = [
            (123_456_789, "createPrivateChat(force: false, userId: 123456789)"),
            (-123_456_789, "createBasicGroupChat(basicGroupId: 123456789, force: false)"),
            (-1_001_234_567_890, "createSupergroupChat(force: false, supergroupId: 1234567890)"),
        ]
        for (chatId, request) in cases {
            let (result, requests) = await load(chatId, get: { throw notFound })
            XCTAssertEqual(try? result.get(), "created", "\(chatId)")
            XCTAssertEqual(requests, [request], "\(chatId)")
        }
    }

    /// TDLib has no information about the user or group: the `getChat` error is reported
    /// (the caller asked about the chat), as `unknownChat`, which carries the hint.
    func testChatInfoNotFoundIsReportedAsAnUnknownChat() async {
        let (result, requests) = await load(-1_001_234_567_890, get: { throw notFound }, create: { _ in
            throw TDError.tdlibError(code: 400, message: "Chat info not found")
        })
        let reported = unknownChat(error(result))
        XCTAssertEqual(reported?.chatId, -1_001_234_567_890, "\(String(describing: error(result)))")
        XCTAssertEqual(reported?.code, 400)
        XCTAssertEqual(reported?.message, "Chat not found")
        XCTAssertEqual(requests.count, 1)
    }

    /// Any other answer to the create request says more than "Chat not found" and gets no
    /// hint: "Can't access the chat" (a private supergroup or channel the account has left
    /// or is banned from, where `get_chats` cannot help), a server error, a rate limit the archive waits out, a closed session.
    func testOtherCreateErrorsPassThroughUnchanged() async {
        let thrown: [Error] = [
            TDError.tdlibError(code: 400, message: "Can't access the chat"),
            TDError.tdlibError(code: 400, message: "CHANNEL_PRIVATE"),
            TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30"),
            TDError.sessionClosed,
        ]
        for answer in thrown {
            let (result, _) = await load(123_456_789, get: { throw notFound }, create: { _ in throw answer })
            XCTAssertNil(unknownChat(error(result)), "\(answer)")
            XCTAssertEqual(error(result).map { String(describing: $0) }, String(describing: answer))
        }
        let (rateLimited, _) = await load(123_456_789, get: { throw notFound }, create: { _ in
            throw TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30")
        })
        XCTAssertEqual(error(rateLimited).flatMap(ChatArchiver.floodWaitSeconds), 30)
    }

    /// Secret chats and ids TDLib does not use: nothing is created and TDLib's own error is
    /// reported unchanged, without a hint (`get_chats` cannot make up an id).
    func testAnIdNoChatCanBeCreatedFromKeepsTheGetChatError() async {
        for (chatId, message) in [(Int64(-1_997_852_516_353), "Chat not found"),
                                  (0, "Invalid chat identifier specified")] {
            let (result, requests) = await load(chatId, get: { throw TDError.tdlibError(code: 400, message: message) })
            XCTAssertEqual(requests, [], "\(chatId)")
            XCTAssertNil(unknownChat(error(result)), "\(chatId)")
            XCTAssertEqual(error(result).map { String(describing: $0) },
                           String(describing: TDError.tdlibError(code: 400, message: message)))
        }
    }

    /// Only a 400 from `getChat` means TDLib may not know the chat; a rate limit or a closed
    /// session is reported as it is, and nothing is created.
    func testOtherGetChatErrorsPassThroughWithoutACreateRequest() async {
        for thrown in [TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30"), .sessionClosed] {
            let (result, requests) = await load(123_456_789, get: { throw thrown })
            XCTAssertEqual(requests, [])
            XCTAssertNil(unknownChat(error(result)), "\(thrown)")
            XCTAssertEqual(error(result).map { String(describing: $0) }, String(describing: thrown))
        }
    }

    /// The hint names the chat and the next step, and the case `get_chats` does not reach;
    /// the CLI prints code, message and hint.
    func testUnknownChatCarriesAHint() throws {
        let error = TDError.unknownChat(chatId: -1_001_234_567_890, code: 400, message: "Chat not found")
        let hint = try XCTUnwrap(error.hint)
        XCTAssertTrue(hint.contains("-1001234567890"), hint)
        XCTAssertTrue(hint.contains("get_chats"), hint)
        XCTAssertTrue(hint.contains("archived"), "get_chats reads the main chat list only: \(hint)")
        XCTAssertFalse(hint.contains("search_chats"), "searchChats searches only chats TDLib already knows")
        XCTAssertEqual(error.errorDescription, "TDLib error 400: Chat not found. " + hint)
        XCTAssertNil(TDError.tdlibError(code: 400, message: "Chat not found").hint)
        XCTAssertNil(TDError.sessionClosed.hint)
    }
}
