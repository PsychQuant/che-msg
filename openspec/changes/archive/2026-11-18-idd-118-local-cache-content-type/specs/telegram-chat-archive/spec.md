## MODIFIED Requirements

### Requirement: Archive from the local cache

While another process holds TDLib, the tool SHALL read messages through the local reader, write day files under the same rules, download no media, count the media messages it archived in `media_pending_local_cache`, and return `source: "local-cache"` and `bookmark_safe: false` with `bookmark_unsafe_reason: "local-cache"`. Incoming senders SHALL be labelled `User <user_id>` because the local reader does not resolve names. Every block this call adds SHALL carry the provisional marker, because it lacks what the local reader cannot give (sender names, captions, poll, sticker and location details). A later call through TDLib that archives the same messages SHALL upgrade those blocks under the merge rule; such a call reaches them without a new argument because a local-cache call never advances the bookmark, and a call with an older `after_message_id` reaches blocks below a bookmark. Blocks written from the local cache by a version of the tool without the marker SHALL be kept unchanged, like any block that is not provisional. The tool's description and the README SHALL say that blocks written from the local cache are provisional until a call through TDLib replaces them. A message the local reader returns without a date SHALL NOT be written, because its day is unknown, and SHALL be counted in `undated_messages_skipped`; it is not lost, because such a run never advances the bookmark and a later TDLib run of the same range adds it.

#### Scenario: Another session holds TDLib

- **WHEN** `archive_chat_to_markdown` is called while process 4242 holds TDLib
- **THEN** day files are written from the local cache with every new block provisional, the manifest has `source: "local-cache"` and `bookmark_safe: false`, and no TDLib client is created in the server process

#### Scenario: Cache record without a date

- **WHEN** the local reader returns messages 30 and 20 for chat 777 and message 20 has no date
- **THEN** only message 30 is written, the manifest has `undated_messages_skipped: 1` and `new_messages: 1`, and `bookmark_safe` is false

#### Scenario: Audio archived from the local cache

- **WHEN** the local reader returns an audio message and its media directory does not exist
- **THEN** its block has the label `[audio](media/<message_id>/)` and the message counts in `media_pending_local_cache`

##### Example: cached audio counts as pending media

- **GIVEN** the local reader returns message 30 of chat 777 with `type` `audio`, and `777/media/30/` does not exist
- **WHEN** `archive_chat_to_markdown` is called while another process holds TDLib
- **THEN** the day file's block for message 30 has the body `[audio](media/30/)` after its provisional marker and header, and the manifest has `media_pending_local_cache: 1`
