import Foundation

/// One conversation's archive directory, `<output_dir>/<team_id>/<conversation_id>/`,
/// and the only code that touches the file system for it (spec:
/// slack-chat-archive, "Slack day file format").
///
/// Safe defaults:
/// - `output_dir` and any missing parent are created; every directory the
///   tool creates gets mode 0700, set exactly whatever the umask. Existing
///   directories keep their mode.
/// - `output_dir` and its parents may be symbolic links (macOS keeps
///   `/tmp` and `/var` behind one). The team and conversation directories,
///   which the tool owns, and the day files must not be: a link would send
///   other people's messages somewhere the caller did not name.
/// - A day file is replaced atomically: written to a temporary file (mode
///   0600) in the same directory, then renamed over the original. On
///   failure the temporary file is removed and the original is untouched.
/// - Day files already written with another `utc_offset` (or without a
///   readable one) are not merged into, as in che-telegram-all-mcp.
///
/// Every refusal is a `ToolFailure` naming the path or the argument.
struct ArchiveDirectory {
    let outputDir: URL
    let teamID: String
    let conversationID: String

    var teamDir: URL { outputDir.appendingPathComponent(teamID, isDirectory: true) }
    var conversationDir: URL { teamDir.appendingPathComponent(conversationID, isDirectory: true) }

    /// The path of `day`'s file relative to `output_dir`.
    func relativePath(day: String) -> String { "\(teamID)/\(conversationID)/\(day).md" }

    init(outputDir: URL, teamID: String, conversationID: String) throws(ToolFailure) {
        // The ids become directory names, so each must be a plain Slack id.
        guard ToolArguments.isSlackID(teamID) else {
            throw ToolFailure("The workspace's team id is not letters and digits only, so it cannot name a directory "
                              + "under output_dir; import the workspace again.")
        }
        guard ToolArguments.isSlackID(conversationID) else {
            throw ToolFailure("conversation_id must be a Slack id made of letters and digits.")
        }
        self.outputDir = outputDir
        self.teamID = teamID
        self.conversationID = conversationID
    }

    // MARK: - Before Slack is called

    /// Refuses, before anything is fetched or written, an `output_dir` that
    /// is not a directory, a team or conversation directory that is a link
    /// or not a directory, a day file that is not a regular file, and day
    /// files written at another offset.
    func preflight(utcOffset: String) throws(ToolFailure) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw ToolFailure("output_dir \(outputDir.path) exists and is not a directory.")
        }
        try Self.checkOwnDirectory(teamDir)
        try Self.checkOwnDirectory(conversationDir)
        try checkDayFiles(utcOffset: utcOffset)
    }

    /// Every file named like a day file in the conversation directory must
    /// be a regular file recording `utcOffset` (compared as an offset, so
    /// `-00:00` equals `+00:00`). Other files are left alone.
    private func checkDayFiles(utcOffset: String) throws(ToolFailure) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: conversationDir.path)
        } catch {
            if !FileManager.default.fileExists(atPath: conversationDir.path) { return }   // first run
            throw ToolFailure("Could not list \(conversationDir.path) to check its day files.")
        }
        for name in names.sorted() where Self.isDayFileName(name) {
            let file = conversationDir.appendingPathComponent(name)
            try Self.checkRegularFile(file)
            let head = FileHandle(forReadingAtPath: file.path).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 512)
            }
            try Self.checkOffset(recordedIn: String(decoding: head ?? Data(), as: UTF8.self), file: file,
                                 utcOffset: utcOffset)
        }
    }

    static func isDayFileName(_ name: String) -> Bool {
        name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$"#, options: .regularExpression) != nil
    }

    // MARK: - Writing

    /// Creates `output_dir` (with any missing parent), the team and the
    /// conversation directory where missing, each 0700.
    func createDirectories() throws(ToolFailure) {
        var missing: [URL] = []
        var current = outputDir
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        for directory in missing.reversed() { try Self.makeDirectory(directory) }
        for directory in [teamDir, conversationDir] {
            try Self.checkOwnDirectory(directory)
            try Self.makeDirectory(directory)
            try Self.checkOwnDirectory(directory)
        }
    }

    /// Merges `messages` into `day`'s file and replaces it when its content
    /// changes. Returns whether the file changed and the ts it did not hold.
    func write(day: String, messages: [ArchivedMessage], utcOffset: String) throws(ToolFailure)
        -> (changed: Bool, added: [String]) {
        let file = conversationDir.appendingPathComponent("\(day).md")
        let existing = try readExisting(file, utcOffset: utcOffset)
        let (content, added) = SlackDayFile.merged(existing: existing, teamID: teamID, conversationID: conversationID,
                                                   day: day, utcOffset: utcOffset, messages: messages)
        if content == existing { return (false, added) }
        try Self.replace(file, with: Data(content.utf8))
        return (true, added)
    }

    private func readExisting(_ file: URL, utcOffset: String) throws(ToolFailure) -> String? {
        guard try Self.checkRegularFile(file) else { return nil }
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8) else {
            throw ToolFailure("The day file \(file.path) cannot be read as UTF-8 text; move it aside or restore it.")
        }
        try Self.checkOffset(recordedIn: text, file: file, utcOffset: utcOffset)
        return text
    }

    /// Writes `data` to a new 0600 temporary file next to `file`, then
    /// renames it over `file`. The temporary file never outlives a failure,
    /// which `failure` words from the `errno` (by default as a day file's).
    static func replace(_ file: URL, with data: Data,
                        failure: ((Int32) -> ToolFailure)? = nil) throws(ToolFailure) {
        let describe = failure ?? { writeFailure(file, $0) }
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw describe(errno) }
        var code: Int32?
        if fchmod(descriptor, 0o600) != 0 {
            code = errno
        } else if !writeAll(descriptor, data) {
            code = errno
        }
        if close(descriptor) != 0, code == nil { code = errno }
        if code == nil, rename(temporary.path, file.path) != 0 { code = errno }
        if let code {
            unlink(temporary.path)
            throw describe(code)
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
    }

    private static func writeFailure(_ file: URL, _ code: Int32) -> ToolFailure {
        ToolFailure("Could not write the day file \(file.path): \(String(cString: strerror(code))). That file was left "
                    + "as it was; day files written earlier in this call are kept.")
    }

    // MARK: - Checks

    /// Creates `url` with mode 0700, or leaves an existing directory as it is.
    private static func makeDirectory(_ url: URL) throws(ToolFailure) {
        if mkdir(url.path, 0o700) == 0 {
            // mkdir applies the umask; the mode is set exactly afterwards.
            guard chmod(url.path, 0o700) == 0 else { throw directoryFailure(url, errno) }
            return
        }
        let code = errno
        var isDirectory: ObjCBool = false
        guard code == EEXIST, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw directoryFailure(url, code) }
    }

    private static func directoryFailure(_ url: URL, _ code: Int32) -> ToolFailure {
        ToolFailure("Could not create the directory \(url.path): \(String(cString: strerror(code))).")
    }

    /// A directory the tool owns must be a real directory when it exists.
    private static func checkOwnDirectory(_ url: URL) throws(ToolFailure) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ToolFailure("Could not inspect \(url.path): \(String(cString: strerror(errno))).")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return
        case S_IFLNK:
            throw ToolFailure("\(url.path) is a symbolic link; the archive is not written through it. Replace it with "
                              + "a directory or choose another output_dir.")
        default:
            throw ToolFailure("\(url.path) exists and is not a directory.")
        }
    }

    /// True when `file` is a regular file, false when it does not exist;
    /// refuses anything else (a link, a directory).
    @discardableResult
    static func checkRegularFile(_ file: URL) throws(ToolFailure) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw ToolFailure("Could not inspect \(file.path): \(String(cString: strerror(errno))).")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ToolFailure("\(file.path) is not a regular file (a symbolic link or a directory); the archive does "
                              + "not write through it. Move it aside.")
        }
        return true
    }

    /// Refuses `utcOffset` for a day file whose frontmatter records another
    /// offset or none.
    private static func checkOffset(recordedIn text: String, file: URL, utcOffset: String) throws(ToolFailure) {
        guard let recorded = recordedOffset(text), let seconds = SlackDayFile.offsetSeconds(recorded) else {
            throw ToolFailure("The day file \(file.path) has no readable utc_offset in its frontmatter (or uses CRLF "
                              + "line endings), so it cannot be merged into safely; move it aside or restore it.")
        }
        guard seconds == SlackDayFile.offsetSeconds(utcOffset) else {
            throw ToolFailure("utc_offset \(utcOffset) differs from \(recorded), the offset the day files in "
                              + "\(file.deletingLastPathComponent().path) were written with; archive this "
                              + "conversation with utc_offset \(recorded).")
        }
    }

    /// The well-formed `utc_offset` in the leading frontmatter, or nil.
    /// Lines are split on LF only, as the tool writes them.
    static func recordedOffset(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst().prefix(8) {
            if line == "---" { break }
            guard line.hasPrefix("utc_offset: ") else { continue }
            let value = line.dropFirst("utc_offset: ".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return SlackDayFile.offsetSeconds(value) == nil ? nil : value
        }
        return nil
    }
}
