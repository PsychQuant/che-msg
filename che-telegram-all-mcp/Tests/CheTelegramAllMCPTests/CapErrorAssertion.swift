import XCTest
@testable import CheTelegramAllMCPCore

/// Asserts that `error` is the cap error for `field` and names the rejected value (#24).
///
/// Only the stable part is pinned: the message starts with "`field` exceeds" and contains
/// "got `value`" (not followed by another digit). The cap number, the advice and the punctuation after it may change
/// without failing these tests; the boundary tests (10_000 accepted, 10_001 rejected) pin
/// the cap itself. Short messages elsewhere keep exact-equality asserts (#11).
func assertCapError(_ error: Error, field: String, got value: Int,
                    file: StaticString = #filePath, line: UInt = #line) {
    guard let description = (error as? HandlerArgError)?.description else {
        return XCTFail("expected a HandlerArgError, got \(error)", file: file, line: line)
    }
    XCTAssertTrue(description.hasPrefix("\(field) exceeds"),
                  "cap error should start with \"\(field) exceeds\": \(description)", file: file, line: line)
    // "got 5000" must not match "got 50000": no digit may follow the value.
    XCTAssertNotNil(description.range(of: "got \(value)(?![0-9])", options: .regularExpression),
                    "cap error should name the rejected value \(value): \(description)", file: file, line: line)
}
