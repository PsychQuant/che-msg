## ADDED Requirements

### Requirement: Message objects carry poll, sticker and location details

In TDLib mode, every message object the server returns (from `get_chat_history`, `search_messages` and any other tool that returns messages) SHALL carry, besides `id`, `chat_id`, `date`, `sender`, `is_outgoing` and `type`: for `type` `poll`, `question` (the text of the poll's question) and `options` (an array holding the text of each answer option, in the poll's order); for `type` `sticker`, `emoji`; for `type` `location`, `latitude` and `longitude` as JSON numbers, as TDLib reports them. Vote counts, the chosen options and a quiz's correct answer SHALL NOT be included. Message objects answered from TDLib's local cache omit these fields, because the local reader does not decode them.

#### Scenario: Poll options in the message JSON

- **WHEN** `get_chat_history` returns message 7000, a poll asking `Lunch?` with the options `Noodles` and `Rice`
- **THEN** its message object has `"type":"poll"`, `"question":"Lunch?"` and `"options":["Noodles","Rice"]`

#### Scenario: Location in the message JSON

- **WHEN** `get_chat_history` returns a location message at latitude 25.0478 and longitude 121.5319
- **THEN** its message object has `"type":"location"`, `"latitude":25.0478` and `"longitude":121.5319`

## MODIFIED Requirements

### Requirement: Markdown output format

The Markdown file produced by `dump_chat_to_markdown` SHALL conform to the following structure:

- A level-1 heading with chat identifier, e.g. `# 對話：<chat title> (chat_id=<id>)`.
- A metadata line listing export timestamp, total message count, and active date range.
- A horizontal rule (`---`) separating metadata from content.
- Level-2 headings per calendar day in local timezone, formatted `## YYYY-MM-DD`, in chronological order (oldest day first within the exported range).
- Each message rendered as `**HH:mm <sender>**：` followed by a newline and the message body on the next line(s).
- Outgoing messages MUST use the configured `self_label` value as `<sender>`.
- Non-text message types MUST render as bracketed placeholders: `[photo]`, `[voice]`, `[video]`, `[video_note]`, `[sticker]`, `[document]`, `[location]`, `[animation]`, `[poll]`, `[audio]`, `[other]`. The placeholder MUST be followed by a space and the message's inline detail when it has one, and, for a poll, by its option lines. The detail of a non-text message is determined by its type: for `poll`, the inline detail is the poll's `question` (its own line breaks kept), followed by one line `- <option>` for each non-empty entry of `options`, in order, with line breaks inside an option written as spaces; for `sticker`, the inline detail is its `emoji`; for `location`, the inline detail is `<latitude>,<longitude>` when both are finite numbers, each written in plain decimal notation with the fewest digits that reproduce TDLib's value exactly (no rounding and no exponent); for any other non-text type, the inline detail is its `caption` (photo, video, voice note, document, animation, audio), with the caption's own line breaks kept. An absent or empty inline detail MUST be treated as none. A dump answered from TDLib's local cache has no captions and no poll, sticker or location details, because that reader does not decode them (the `telegram-local-reader` capability omits a field it cannot determine).
- Consecutive messages from the same sender MUST each retain their own timestamp line; the implementation MUST NOT merge them into a single block.

#### Scenario: Text message formatting

- **WHEN** an outgoing text message "會議幾點開始？" is sent at 2026-04-14 14:32 local time
- **AND** `self_label` is `"我"`
- **THEN** the Markdown output contains `**14:32 我**：\n會議幾點開始？` under the `## 2026-04-14` heading

#### Scenario: Photo placeholder

- **WHEN** a message of type `messagePhoto` with no caption (TDLib's caption text is empty) is encountered
- **THEN** the Markdown body for that message is exactly `[photo]`

#### Scenario: Caption kept

- **WHEN** a message of type `messagePhoto` has the caption `menu`
- **THEN** the Markdown body for that message is exactly `[photo] menu`

#### Scenario: Poll with its options

- **WHEN** a poll message asks `Lunch?` with the options `Noodles` and `Rice`
- **THEN** the Markdown body for that message is exactly `[poll] Lunch?\n- Noodles\n- Rice`

#### Scenario: Sticker and location details

- **WHEN** a sticker message has the emoji `😀` and a location message is at latitude 25.0478 and longitude 121.5319
- **THEN** their Markdown bodies are exactly `[sticker] 😀` and `[location] 25.0478,121.5319`

#### Scenario: Coordinate near zero

- **WHEN** a location message is at latitude 0.00001 and longitude -0.5
- **THEN** the Markdown body for that message is exactly `[location] 0.00001,-0.5`

#### Scenario: Poll from the local cache

- **WHEN** `dump_chat_to_markdown` is answered from TDLib's local cache and the chat holds a poll message
- **THEN** the Markdown body for that message is exactly `[poll]`

#### Scenario: Day heading chronological order

- **WHEN** the exported range spans 2026-04-12 through 2026-04-14
- **THEN** day headings appear in the order `## 2026-04-12`, `## 2026-04-13`, `## 2026-04-14`
