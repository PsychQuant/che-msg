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
