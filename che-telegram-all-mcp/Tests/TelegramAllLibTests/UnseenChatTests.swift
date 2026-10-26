import XCTest
@testable import TelegramAllLib

/// A chat TDLib has not loaded is loaded by its id before a tool's first request on it
/// (PsychQuant/che-msg#71). A new login has seen few chats, and `get_chat_history` on any
/// other answered "Chat not found"; only the archive created the chat from its id (#69).
///
/// `loadChat` takes the `getChat` and create requests as closures, so the decision is tested
/// here without TDLib; `TDLibRequestTests` checks that every method taking a chat id uses it.
final class UnseenChatTests: XCTestCase {
    private typealias TDError = TDLibClient.TDError
    private let notFound = TDError.tdlibError(code: 400, message: "Chat not found")

    private func unknownChat(_ error: Error) -> (chatId: Int64, code: Int, message: String)? {
        guard case TDError.unknownChat(let chatId, let code, let message) = error else { return nil }
        return (chatId, code, message)
    }

    private func tdlibError(_ error: Error) -> (code: Int, message: String)? {
        guard case TDError.tdlibError(let code, let message) = error else { return nil }
        return (code, message)
    }

    func testAKnownChatIsNotCreated() async throws {
        var created: [TDLibChatID] = []
        let chat = try await loadChat(123_456_789, get: { "known" }, create: { created.append($0); return "created" })
        XCTAssertEqual(chat, "known")
        XCTAssertEqual(created, [])
    }

    /// One create request, of the kind the id names, and its chat is the result.
    func testAnUnseenChatIsCreatedFromItsId() async throws {
        for (chatId, kind) in [(123_456_789, TDLibChatID.user(123_456_789)),
                               (-123_456_789, .basicGroup(123_456_789)),
                               (-1_001_234_567_890, .supergroup(1_234_567_890))] as [(Int64, TDLibChatID)] {
            var created: [TDLibChatID] = []
            let chat = try await loadChat(chatId, get: { () async throws -> String in throw notFound },
                                          create: { created.append($0); return "created" })
            XCTAssertEqual(chat, "created", "\(chatId)")
            XCTAssertEqual(created, [kind], "\(chatId)")
        }
    }

    /// The caller asked about the chat, so the `getChat` error is reported, not the create
    /// request's ("Supergroup not found" would suggest the id has the wrong kind).
    func testAChatThatCannotBeCreatedReportsTheOriginalError() async {
        do {
            _ = try await loadChat(-1_001_234_567_890, get: { () async throws -> String in throw notFound },
                                   create: { _ in throw TDError.tdlibError(code: 400, message: "Supergroup not found") })
            XCTFail("expected an error")
        } catch {
            let reported = unknownChat(error)
            XCTAssertEqual(reported?.chatId, -1_001_234_567_890, "\(error)")
            XCTAssertEqual(reported?.code, 400)
            XCTAssertEqual(reported?.message, "Chat not found")
        }
    }

    /// Secret chats and ids TDLib does not use: nothing to create them from, so no request.
    func testAnIdNoChatCanBeCreatedFromSendsNoCreateRequest() async {
        for chatId: Int64 in [-1_997_852_516_353, 0] {
            var created: [TDLibChatID] = []
            do {
                _ = try await loadChat(chatId, get: { () async throws -> String in
                    throw TDError.tdlibError(code: 400, message: "Invalid chat identifier")
                }, create: { created.append($0); return "created" })
                XCTFail("expected an error: \(chatId)")
            } catch {
                XCTAssertEqual(unknownChat(error)?.message, "Invalid chat identifier", "\(error)")
            }
            XCTAssertEqual(created, [], "\(chatId)")
        }
    }

    /// Only a 400 from `getChat` means TDLib may not know the chat; a rate limit or a closed
    /// session is reported as it is, and nothing is created.
    func testOtherGetChatErrorsPassThroughWithoutACreateRequest() async {
        for thrown in [TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30"), .sessionClosed] {
            var created: [TDLibChatID] = []
            do {
                _ = try await loadChat(123_456_789, get: { () async throws -> String in throw thrown },
                                       create: { created.append($0); return "created" })
                XCTFail("expected an error")
            } catch {
                XCTAssertNil(unknownChat(error), "\(error)")
                XCTAssertEqual(String(describing: error), String(describing: thrown))
            }
            XCTAssertEqual(created, [])
        }
    }

    /// The archive waits out a rate limit, so one from the create request stays a rate limit.
    func testOtherCreateErrorsPassThrough() async {
        do {
            _ = try await loadChat(123_456_789, get: { () async throws -> String in throw notFound },
                                   create: { _ in throw TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30") })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(tdlibError(error)?.code, 429, "\(error)")
            XCTAssertEqual(tdlibError(error)?.message, "Too Many Requests: retry after 30")
            XCTAssertEqual(ChatArchiver.floodWaitSeconds(error), 30)
        }
        do {
            _ = try await loadChat(123_456_789, get: { () async throws -> String in throw notFound },
                                   create: { _ in throw TDError.sessionClosed })
            XCTFail("expected an error")
        } catch TDError.sessionClosed {
        } catch {
            XCTFail("changed: \(error)")
        }
    }

    /// The hint names the chat and the next step; the CLI prints code, message and hint.
    func testUnknownChatCarriesAHint() throws {
        let error = TDError.unknownChat(chatId: -1_001_234_567_890, code: 400, message: "Chat not found")
        let hint = try XCTUnwrap(error.hint)
        XCTAssertTrue(hint.contains("-1001234567890"), hint)
        XCTAssertTrue(hint.contains("get_chats"), hint)
        XCTAssertFalse(hint.contains("search_chats"), "searchChats searches only chats TDLib already knows")
        XCTAssertEqual(error.errorDescription, "TDLib error 400: Chat not found. " + hint)
        XCTAssertNil(TDError.tdlibError(code: 400, message: "Chat not found").hint)
        XCTAssertNil(TDError.sessionClosed.hint)
    }
}
