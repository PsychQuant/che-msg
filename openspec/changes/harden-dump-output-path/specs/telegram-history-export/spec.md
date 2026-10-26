## MODIFIED Requirements

### Requirement: Output path validation and error reporting

Before fetching messages, the `dump_chat_to_markdown` implementation SHALL validate `output_path` in two stages. If either stage fails, the tool MUST return an error result and MUST NOT issue any TDLib call or local-cache read for message retrieval (PsychQuant/che-msg#21).

First, argument parsing SHALL refuse an `output_path` that:

- is not an absolute path, that is, does not begin with `/` (`~` is not expanded, and an empty string is refused);
- contains a `..` path component (a component that is exactly `..`; names such as `..md` are allowed);
- does not end in `.md` in any letter case (`.md`, `.MD`, `.Md`, `.mD`; a trailing `/` is not a match).

The rules SHALL be checked in that order, and the error message SHALL name the failed rule and quote the given value.

Second, before writing, the implementation SHALL verify that the parent directory of `output_path` exists and is writable by the current process. If it is not, the implementation MUST throw a distinguishable error (not a generic IO error) with the invalid path included in the error payload.

When the server process starts with the environment variable `CHE_TELEGRAM_ALL_EXPORT_ROOT` set to a non-empty value, the implementation SHALL also, before the parent-directory check, restrict `output_path` to that root:

- The root SHALL be resolved with symbolic links followed. A root that is not an absolute path to an existing directory SHALL make every dump fail with an error naming the configured root; the setting MUST NOT be ignored.
- `output_path` SHALL be resolved by following symbolic links on its longest existing prefix (an existing symbolic link counts as existing, even when it points nowhere) and appending the remaining components.
- The dump SHALL be refused, with an error naming both the path and the configured root, when the resolved path does not lie strictly inside the resolved root, when a remaining component is `..`, when the existing prefix cannot be resolved (for example a dangling symbolic link or a loop), when a prefix cannot be examined for any reason other than not existing, or when the path contains a NUL character.

When `CHE_TELEGRAM_ALL_EXPORT_ROOT` is unset or empty, no root restriction SHALL apply. The server SHALL read the variable once, at startup.

Both write paths of `dump_chat_to_markdown` SHALL apply these checks: TDLib mode, and the local-cache reader used while another process holds TDLib. The root restriction SHALL NOT apply to `archive_chat_to_markdown` or `download_message_media`, whose `output_dir` is chosen per workspace, and none of these checks SHALL apply to the `telegram-all history --dump-markdown` CLI flag.

#### Scenario: Parent directory missing

- **WHEN** `dump_chat_to_markdown(output_path: "/nonexistent/dir/chat.md")` is invoked and `CHE_TELEGRAM_ALL_EXPORT_ROOT` is unset
- **THEN** the tool returns an error result naming the invalid path `/nonexistent/dir/chat.md`
- **AND** no TDLib message fetch is attempted

#### Scenario: Writable path succeeds

- **WHEN** `dump_chat_to_markdown(output_path: "/tmp/chat.md")` is invoked, `/tmp` is writable, and `CHE_TELEGRAM_ALL_EXPORT_ROOT` is unset
- **THEN** validation passes and message fetching proceeds

#### Scenario: Relative path refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "chat.md")` is invoked
- **THEN** the tool returns an error result `Error: output_path must be an absolute path; got "chat.md"`
- **AND** no message is fetched and no file is written

#### Scenario: Traversal component refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/exports/../../Users/me/notes.md")` is invoked
- **THEN** the tool returns an error result stating that `output_path` must not contain `..` components, quoting the given value
- **AND** no message is fetched

#### Scenario: Non-Markdown target refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/Users/me/.zshrc")` is invoked
- **THEN** the tool returns an error result `Error: output_path must end in .md; got "/Users/me/.zshrc"`
- **AND** `/Users/me/.zshrc` is left unchanged

#### Scenario: Upper-case extension accepted

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/CHAT.MD")` is invoked and `/tmp` is writable
- **THEN** argument parsing accepts the path and message fetching proceeds

#### Scenario: Path inside the export root accepted

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, the directory `/Users/me/exports/2026` exists, and `dump_chat_to_markdown(chat_id: 123, output_path: "/Users/me/exports/2026/chat.md")` is invoked
- **THEN** validation passes and message fetching proceeds

#### Scenario: Path outside the export root refused

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports` and `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/chat.md")` is invoked
- **THEN** the tool returns an error result naming `/tmp/chat.md` and the root `/Users/me/exports`
- **AND** no message is fetched and no file is written

#### Scenario: Symbolic link escape refused

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, `/Users/me/exports/link` is a symbolic link to `/Users/me/.config`, and `dump_chat_to_markdown(chat_id: 123, output_path: "/Users/me/exports/link/chat.md")` is invoked
- **THEN** the tool returns an error result naming the path and the root
- **AND** nothing is written under `/Users/me/.config`

#### Scenario: Unusable export root refuses every dump

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=exports` (a relative path) or with the path of a directory that does not exist, and `dump_chat_to_markdown` is invoked with any `output_path`
- **THEN** the tool returns an error result naming the configured root
- **AND** no message is fetched

#### Scenario: Local-cache dump honours the export root

- **WHEN** another process holds TDLib, the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, and `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/chat.md")` is invoked
- **THEN** the tool returns an error result naming the path and the root
- **AND** the local cache is not read and no file is written
