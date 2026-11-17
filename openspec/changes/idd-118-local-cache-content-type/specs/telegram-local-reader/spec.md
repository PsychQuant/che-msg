## MODIFIED Requirements

### Requirement: Reader answers five tools with the TDLib-mode JSON fields

The local reader SHALL answer `get_chats`, `search_chats`, `get_chat_history`, `search_messages` and `dump_chat_to_markdown`. Chat objects SHALL use the fields `id`, `title`, `type` and, when the cache holds a message for the chat, `last_message` (the newest cached message; one that cannot be decoded appears as "Undecodable records are reported, not guessed" describes). Message objects SHALL use the fields `id`, `chat_id`, `date`, `sender`, `is_outgoing`, `type`, `text` or `caption` when present, and `content_type` when present. A field the reader cannot determine SHALL be omitted rather than filled with a placeholder value. A message whose decoded internal content type is `Audio` SHALL have `type` `audio`, as in TDLib mode. A message whose `type` is `other` SHALL carry `content_type`, the TDLib API constructor name that TDLib 1.8.60's `get_message_content_object` returns for its internal content type (for example `messageContact` for `Contact`, `messageBasicGroupChatCreate` for `ChatCreate`), when that function returns one constructor for that internal type whatever the payload. For the internal content types where it chooses between constructors by the payload — `ChatChangePhoto`, `ChatJoinedByLink`, `PaymentSuccessful`, `Dice`, `GroupCall`, `TopicEdit`, `SuggestProfilePhoto`, `RequestedDialog`, `DialogShared`, `StarGiftUnique`, `PaidMessagesPrice` and `SuggestedPostApproval` — the reader SHALL omit `content_type`, because it does not decode the payload. A message whose `type` is not `other` SHALL NOT carry `content_type`. `get_chat_history` SHALL accept the same arguments as in TDLib mode, including its date range filters. `dump_chat_to_markdown` SHALL produce the Markdown format defined by the `telegram-history-export` capability. Message text SHALL come from decoding the message `data`, not from the `text` column. `search_messages` SHALL return the messages whose decoded text contains the query as a case-insensitive substring.

#### Scenario: Search matches decoded text

- **WHEN** `search_messages` is called with query `HELLO` for a chat whose cached messages decode to the texts "hello there" and "bye"
- **THEN** the result contains only the message whose text is "hello there"

#### Scenario: Chat history from the local cache

- **WHEN** `get_chat_history` is called for a private chat whose messages exist in the cache
- **THEN** the first content item is a JSON array of message objects ordered as in TDLib mode, each with `id`, `chat_id`, `date`, `sender`, `is_outgoing`, `type`, and `text` for text messages

##### Example: one text message

- **GIVEN** the cache holds message 5242880 in chat 777 sent by user 1001 at Unix time 1760000000 with text "hello"
- **WHEN** `get_chat_history` is called with `chat_id` 777
- **THEN** the array contains `{"id":5242880,"chat_id":777,"date":1760000000,"sender":{"type":"user","user_id":1001},"is_outgoing":false,"type":"text","text":"hello"}`

#### Scenario: Content type of a message the reader does not map

- **WHEN** the cache holds a message whose internal content type is outside the types the reader maps to a named `type`
- **THEN** its object has `type` `other`, and `content_type` exactly when TDLib names that internal type with one constructor

##### Example: a cached contact carries its content type

- **GIVEN** the cache holds message 5242880 in chat 777 sent by user 1001 at Unix time 1760000000 whose internal content type is 8 (`Contact`)
- **WHEN** `get_chat_history` is called with `chat_id` 777
- **THEN** the array contains `{"id":5242880,"chat_id":777,"date":1760000000,"sender":{"type":"user","user_id":1001},"is_outgoing":false,"type":"other","content_type":"messageContact"}`

##### Example: a payload-dependent content type is omitted

- **GIVEN** the cache holds a message whose internal content type is 41 (`Dice`), which TDLib reports as `messageDice` or `messageStakeDice` depending on the payload
- **WHEN** the reader decodes it
- **THEN** its object has `type` `other` and no `content_type`

##### Example: every internal content type has its type and name

- **GIVEN** a cached message for each internal content type from 0 to 85
- **WHEN** the reader decodes them
- **THEN** each has the `type` of TDLib mode (`text` 0, `animation` 1, `audio` 2, `document` 3, `photo` 4, `sticker` 5, `video` 6, `voice_note` 7, `location` 9 and 35, `video_note` 31, `poll` 40, otherwise `other`), the 12 payload-dependent types have no `content_type`, the other 62 have the constructor `get_message_content_object` returns for them, and no message with a named `type` has `content_type`

#### Scenario: Audio from the local cache

- **WHEN** the cache holds a message whose internal content type is 2 (`Audio`)
- **THEN** its object has `type` `audio` and no `content_type`

##### Example: a cached audio message

- **GIVEN** the cache holds message 5242880 in chat 777 sent by user 1001 at Unix time 1760000000 whose internal content type is 2 (`Audio`)
- **WHEN** `get_chat_history` is called with `chat_id` 777, and `dump_chat_to_markdown` is called for the same chat
- **THEN** the array contains `{"id":5242880,"chat_id":777,"date":1760000000,"sender":{"type":"user","user_id":1001},"is_outgoing":false,"type":"audio"}`, and the dump writes the message as `[audio]`

#### Scenario: History pages strictly below from_message_id, like TDLib

- **WHEN** `get_chat_history` is called with a non-zero `from_message_id`, with or without `max_messages`
- **THEN** the result starts at the newest cached message whose id is below `from_message_id`, and does not include the message `from_message_id` itself, as TDLib's `getChatHistory` at offset 0 does

##### Example: paging with the lowest id returned

- **GIVEN** chat 777 holds messages 5242880, 6291456 and 7340032 in the cache
- **WHEN** `get_chat_history` is called with `chat_id` 777, `limit` 1, and `from_message_id` set each time to the lowest id of the previous page (0 at first)
- **THEN** the pages are `[7340032]`, `[6291456]`, `[5242880]`, then `[]`, and no message appears twice

#### Scenario: Unread count omitted

- **WHEN** `get_chats` is answered by the reader and the unread count is not decodable from the cache
- **THEN** chat objects omit `unread_count` instead of reporting 0
