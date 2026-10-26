import XCTest
@testable import TelegramAllLib

/// Every TDLib request outside the four authentication steps reports TDLib's code and
/// message (PsychQuant/che-msg#71). Only the authentication steps and the archive turned
/// TDLibKit's own error into `TDError.tdlibError`, so `get_chat_history` on a chat TDLib had
/// not loaded answered "TDLibKit.Error error 1", and the server, which does not depend on
/// TDLibKit, could not catch it.
///
/// A `TDLibClient` needs a TDLib session, so the conversion is tested on `tdlibCall`
/// (`ArchiveTDLibErrorTests`) and, here, in the sources: every request goes through it.
final class TDLibRequestTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TelegramAllLib")

    /// The four authentication requests keep `mapTDLibError`, under which a 406 completes
    /// silently (spec: "TDLib error code 406 silent-ignore rule"). Two of them go through
    /// `openClient`; the phone number and the 2FA password go through #98's request seam,
    /// `TDLibKitCredentialRequests`, whose answers `AuthCoordinator.mapped` passes through
    /// `mapTDLibError` (`AuthCoordinatorTests.testATDLib406AnswerCountsAsSuccess`).
    private let authenticationRequests = [
        "_ = try await openClient.setTdlibParameters(",
        "_ = try await openClient.checkAuthenticationCode(",
    ]
    private let seamRequests = [
        "try client.setAuthenticationPhoneNumber(",
        "try client.checkAuthenticationPassword(",
    ]

    /// The code lines of every Swift file in TelegramAllLib, comment lines dropped, so a file
    /// added later is covered too.
    private func codeLines() throws -> [(file: String, line: String)] {
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no sources under \(Self.sources.path)")
        return try files.flatMap { url in
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .map { (url.lastPathComponent, $0) }
        }
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Each request is written `tdlibCall { try await openClient.… }` on one line, so a line
    /// with more requests than conversions is a request that lets TDLibKit's error escape.
    func testEveryOtherRequestConvertsTDLibKitErrors() throws {
        var requests = 0
        var authentication = 0
        for (file, line) in try codeLines() where line.contains("openClient.") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if authenticationRequests.contains(where: { text.hasPrefix($0) }) {
                authentication += 1
                continue
            }
            let sent = count("openClient.", in: line)
            requests += sent
            XCTAssertEqual(count("tdlibCall { try await openClient.", in: line), sent,
                           "\(file): a request without tdlibCall: \(text)")
        }
        XCTAssertEqual(authentication, authenticationRequests.count, "each authentication request once")
        let lines = try codeLines()
        for request in seamRequests {
            XCTAssertEqual(lines.filter { $0.line.contains(request) }.map(\.file), ["TDLibClient.swift"],
                           "the request seam sends \(request) once")
        }
        XCTAssertEqual(lines.filter { $0.line.contains("Result { do { try answer.get() } catch { try mapTDLibError(error) } }") }
                        .map(\.file), ["AuthCoordinator.swift"], "the seam's answers go through mapTDLibError")
        XCTAssertGreaterThan(requests, 20, "the chat, message, contact, group and archive requests")
    }

    /// The methods the spec lists as taking a chat id ("A chat TDLib has not loaded is loaded
    /// by its id"); `page` and `message` are the archive's history source and single read.
    private let methodsWithAChatId: Set<String> = [
        "getChat", "getChatHistory", "searchMessages", "sendMessage", "editMessage", "deleteMessages",
        "forwardMessages", "getChatMembers", "pinMessage", "unpinMessage", "setChatTitle",
        "setChatDescription", "addChatMember", "markAsRead", "page", "message",
    ]

    /// Each method in the TDLib client's files that takes a chat id and sends a request makes
    /// every chat id parameter known (`knownChat`) on a line before its first request (#71).
    /// The signature runs to the line that opens the body; the body ends at the next
    /// declaration or comment at the method's indentation.
    func testEveryMethodWithAChatIdLoadsTheChatFirst() throws {
        let declaration = try NSRegularExpression(pattern: #"^    (?:public |private |internal )?func (\w+)\("#)
        let member = try NSRegularExpression(
            pattern: #"^    (?:public |private |internal |static |@\w+ )*(?:func|var|let|init|case|enum|struct|class|//)|^\}"#)
        var checked: Set<String> = []
        for file in ["TDLibClient.swift", "TDLibClient+Archive.swift"] {
            let lines = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                guard let match = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let name = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                      name != "knownChat",
                      let opening = lines[index...].firstIndex(where: { $0.hasSuffix("{") }) else { continue }
                let signature = lines[index...opening].joined(separator: " ")
                let chatIds = ["chatId", "fromChatId"].filter { signature.contains("\($0): Int64") }
                guard !chatIds.isEmpty else { continue }
                var body: [String] = []
                for next in lines[(opening + 1)...] {
                    if member.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil { break }
                    body.append(next)
                }
                // A method that reads elsewhere (the local cache's `page`) sends no TDLib request.
                guard body.contains(where: { $0.contains("openClient.") || $0.contains("knownChat(") }) else { continue }
                let firstRequest = body.firstIndex(where: { $0.contains("openClient.") }) ?? body.count
                checked.insert(name)
                for chatId in chatIds {
                    let loaded = body.firstIndex(where: { $0.contains("knownChat(\(chatId))") })
                    XCTAssertNotNil(loaded, "\(file): \(name) never makes \(chatId) known")
                    if let loaded { XCTAssertLessThan(loaded, firstRequest, "\(file): \(name) sends a request before knownChat(\(chatId))") }
                }
            }
        }
        XCTAssertTrue(checked.isSuperset(of: methodsWithAChatId),
                      "not checked: \(methodsWithAChatId.subtracting(checked).sorted())")
    }

    /// What the `telegram-all` CLI prints for it (ArgumentParser prints `errorDescription`).
    func testTheCLIShowsTheCodeAndTheMessage() {
        XCTAssertEqual(TDLibClient.TDError.tdlibError(code: 400, message: "User not found").errorDescription,
                       "TDLib error 400: User not found")
    }
}
