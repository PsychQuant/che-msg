import Darwin
import Foundation
@testable import SlackWebLib

/// A fresh directory under the system temporary directory, removed when the
/// last reference goes away. Each suite instance (one per test) owns one.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("slack-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    /// Writes an executable bash script that stands in for `/usr/bin/security`.
    func fakeSecurity(_ body: String) throws -> URL {
        let script = url.appendingPathComponent("security-\(UUID().uuidString)")
        try "#!/bin/bash\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return script
    }
}

/// What `security find-generic-password -g` writes for a stored item:
/// attributes on stdout, then `passwordLine` on stderr.
func dashG(_ passwordLine: String) -> String {
    "printf 'keychain: \"/x\"\\nclass: \"genp\"\\n'; printf '%s\\n' '\(passwordLine)' >&2"
}

/// Reads the pid a fake wrote to `file` and waits up to `seconds` for that
/// process to be gone. Returns true when it is gone.
func processIsGone(pidFile file: String, within seconds: Double = 2) throws -> Bool {
    guard let pid = Int32(try String(contentsOfFile: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }
        usleep(20_000)
    }
    kill(pid, SIGKILL)
    return false
}

/// Runs `tool` to completion with stdin and stderr on the null device and
/// returns its stdout; throws on a non-zero exit.
@discardableResult
func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolFailed(tool: tool, subcommand: arguments.first ?? "", status: process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
}

struct ToolFailed: Error, CustomStringConvertible {
    let tool: String
    let subcommand: String
    let status: Int32
    var description: String { "\(tool) \(subcommand) exited \(status)" }
}
