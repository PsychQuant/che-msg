import Foundation

/// `CHE_TELEGRAM_ALL_EXPORT_ROOT`: when set, `dump_chat_to_markdown` writes
/// only inside this directory, symlinks resolved (PsychQuant/che-msg#21).
/// The server reads it once, at startup; `validateOutputPath` applies it.
public enum ExportRoot {
    public static let environmentVariable = "CHE_TELEGRAM_ALL_EXPORT_ROOT"

    /// The root for `value`, or nil when there is none (unset or empty). Any
    /// other value is kept as given, not trimmed: one that is not an absolute
    /// path to an existing directory refuses every dump rather than being
    /// ignored, since ignoring it would leave the user believing in a sandbox.
    public static func parse(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `parse` applied to the process environment.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        parse(environment[environmentVariable])
    }
}

/// `root` with symlinks resolved, or nil when it is not an absolute path to
/// an existing directory.
internal func resolvedExportRoot(_ root: String) -> String? {
    guard ScalarPath.isAbsolute(root), !root.unicodeScalars.contains("\0"), let resolved = realPath(root) else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
        return nil
    }
    return resolved
}

/// `path` with symlinks resolved on its longest existing prefix and the
/// remaining components appended. An entry counts as existing when `lstat`
/// sees it, so a dangling symlink is part of the prefix and makes `realpath`
/// fail. Nil, so that the caller refuses, when the path is relative or holds
/// a NUL (C would read a shorter path), when `lstat` fails other than with
/// `ENOENT`, when the prefix cannot be resolved, or when a remaining component
/// is `..` (it would climb out of a directory that does not exist yet).
/// Components are split by scalar (`ScalarPath`), as the OS splits them.
internal func resolvedOnLongestExistingPrefix(_ path: String) -> String? {
    guard ScalarPath.isAbsolute(path), !path.unicodeScalars.contains("\0") else { return nil }
    var existing = ScalarPath.components(of: path)
    var missing: [String] = []
    while true {
        let prefix = "/" + existing.joined(separator: "/")
        var info = stat()
        let status = lstat(prefix, &info)
        let error = errno
        if status == 0 {
            guard let resolved = realPath(prefix), !missing.contains(where: ScalarPath.isParent) else { return nil }
            let rest = missing.reversed().filter { !ScalarPath.isCurrent($0) }
            return rest.isEmpty ? resolved : ([resolved == "/" ? "" : resolved] + rest).joined(separator: "/")
        }
        guard error == ENOENT, let last = existing.popLast() else { return nil }
        missing.append(last)
    }
}

/// Whether `path` lies strictly inside `root`, compared by path component so
/// that `/a/rootx` is not inside `/a/root`, scalar for scalar (`ScalarPath`).
/// Both are already resolved.
internal func isStrictlyInside(_ path: String, root: String) -> Bool {
    let pathComponents = ScalarPath.components(of: path)
    let rootComponents = ScalarPath.components(of: root)
    return pathComponents.count > rootComponents.count
        && zip(pathComponents, rootComponents).allSatisfy { ScalarPath.same($0, $1) }
}

/// `realpath(3)`, or nil when it fails.
private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
