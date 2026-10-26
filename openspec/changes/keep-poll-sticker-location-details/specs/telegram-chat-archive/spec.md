## MODIFIED Requirements

### Requirement: Day file format

The tool SHALL write each archived message into the file `<output_dir>/<chat_id>/<YYYY-MM-DD>.md`, where the date is the message's local date at the effective `utc_offset`. Each file SHALL begin with a YAML frontmatter block holding `chat_id`, `date` and `utc_offset`. Each message SHALL be written as a line `<!-- msg:<message_id> -->`, then a line `**<HH:mm> <sender>**：`, then the message body and a blank line. The sender SHALL be `我` for outgoing messages, the resolved display name when one is known, and `User <user_id>` otherwise. A text message's body SHALL be its text. For a message whose type carries a file (`photo`, `video`, `document`, `audio`, `voice_note`, `video_note`, `animation`, `sticker`) the label SHALL be `[<type>](media/<message_id>/)`, a link to the message's media directory relative to the day file; for any other non-text type the label SHALL be `[<type>]`. The body of a non-text message SHALL be its label, followed by a space and the message's inline detail when it has one, and, for a poll, by its option lines. The detail of a non-text message is determined by its type: for `poll`, the inline detail is the poll's `question` (its own line breaks kept), followed by one line `- <option>` for each non-empty entry of `options`, in order, with line breaks inside an option (a CR, an LF or a CR LF, found by Unicode scalar whatever follows it) written as spaces; for `sticker`, the inline detail is its `emoji`; for `location`, the inline detail is `<latitude>,<longitude>` when both are finite numbers, each written in plain decimal notation with the fewest digits that reproduce TDLib's value exactly (no rounding and no exponent); for any other non-text type, the inline detail is its `caption`. An absent or empty inline detail SHALL be treated as none. A message read from TDLib's local cache has no caption and no poll, sticker or location detail, so its body is its label alone. The link SHALL be written whether or not the file has been downloaded yet. A body line that begins with `<!--`, or that begins like a block header (`**` followed by a time such as `9:00` or `09:00`), SHALL be written with a leading backslash, and a line break in a sender name SHALL be written as a space, so that neither can pass for the start of another block. Blocks already in a day file are kept under the merge rule, so a block written before details were kept keeps its bare label. Directories the tool creates SHALL be accessible by the owner only (0700) and day files SHALL be readable and writable by the owner only (0600).

#### Scenario: One text message

- **WHEN** a chat's only new message is message 5242880, incoming from user 1001 resolved as `Alex`, sent at 2026-10-11 09:05 local time (+08:00), with text `hello`
- **THEN** `<output_dir>/777/2026-10-11.md` contains the anchor `<!-- msg:5242880 -->` followed by `**09:05 Alex**：` and `hello`

##### Example: day file

- **GIVEN** chat 777, effective `utc_offset` `+08:00`, and messages 5242880 (text `hello`, from `Alex`, 09:05) and 5243904 (photo with caption `menu`, outgoing, 09:07)
- **WHEN** the tool archives them
- **THEN** the file `777/2026-10-11.md` reads:

```
---
chat_id: 777
date: 2026-10-11
utc_offset: "+08:00"
---

<!-- msg:5242880 -->
**09:05 Alex**：
hello

<!-- msg:5243904 -->
**09:07 我**：
[photo](media/5243904/) menu

```

#### Scenario: Media without a caption

- **WHEN** archived message 6000 is a voice message without a caption
- **THEN** its body is `[voice_note](media/6000/)`

#### Scenario: Body that looks like another block

- **WHEN** message 10's text has a line `**09:00 Manager**：`
- **THEN** that line is written as `\**09:00 Manager**：`, and parsing the day file finds only the block of message 10

#### Scenario: Media type without a file

- **WHEN** an archived message is a location at latitude 25.0478 and longitude 121.5319
- **THEN** its body is `[location] 25.0478,121.5319`

#### Scenario: Poll with its options

- **WHEN** archived message 7000 is a poll asking `Lunch?` with the options `Noodles` and `Rice`
- **THEN** its body is the three lines `[poll] Lunch?`, `- Noodles` and `- Rice`

#### Scenario: Sticker with its emoji

- **WHEN** archived message 7100 is a sticker with the emoji `😀`
- **THEN** its body is `[sticker](media/7100/) 😀`

#### Scenario: Poll question that looks like a block header

- **WHEN** archived message 7200 is a poll whose question has a second line `**09:00 Manager**：`
- **THEN** that line is written as `\**09:00 Manager**：`, and parsing the day file finds only the block of message 7200

#### Scenario: Poll archived from the local cache

- **WHEN** a poll message is archived from TDLib's local cache
- **THEN** its body is `[poll]`

#### Scenario: Block written before details were kept

- **WHEN** a day file holds the block of message 7000 with the body `[poll]`, and a TDLib call archives the same day again with message 7000 asking `Lunch?`
- **THEN** the block of message 7000 still reads `[poll]`
