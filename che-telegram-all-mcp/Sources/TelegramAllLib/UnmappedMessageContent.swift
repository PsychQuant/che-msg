import TDLibKit

/// The TDLib constructor name of a TDLibKit enum value, such as `messageContact` or
/// `callDiscardReasonMissed` (PsychQuant/che-msg#117).
///
/// TDLibKit generates each case from the TL constructor of the same name, so the case label is the
/// name TDLib uses; a case with a payload reflects as one child labelled with it, a case without one
/// prints as its name.
func tdlibConstructorName<Value>(_ value: Value) -> String {
    Mirror(reflecting: value).children.first?.label ?? String(describing: value)
}

/// The fields of a message whose content `messageToDict` does not map (its `type` is `other`):
/// `content_type`, the TDLib constructor name, always; and for seven kinds what the content says
/// (PsychQuant/che-msg#117). The list is closed: any other kind gives `content_type` only.
///
/// A contact's phone number and vCard are left out: another person's details, not needed to tell
/// what the message is.
func unmappedContentFields(_ content: MessageContent) -> [String: Any] {
    var fields: [String: Any] = ["content_type": tdlibConstructorName(content)]
    switch content {
    case .messageContact(let message):
        let name = [message.contact.firstName, message.contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        fields["contact_name"] = name
        if message.contact.userId != 0 { fields["contact_user_id"] = message.contact.userId }
    case .messageDice(let dice):
        fields["emoji"] = dice.emoji
        fields["value"] = dice.value
    case .messageCall(let call):
        fields["duration"] = call.duration
        fields["is_video"] = call.isVideo
        fields["discard_reason"] = tdlibConstructorName(call.discardReason)
    case .messageStory(let story):
        fields["story_poster_chat_id"] = story.storyPosterChatId
        fields["story_id"] = story.storyId
        fields["via_mention"] = story.viaMention
    case .messageVenue(let message):
        fields["title"] = message.venue.title
        fields["address"] = message.venue.address
        fields["latitude"] = message.venue.location.latitude
        fields["longitude"] = message.venue.location.longitude
    case .messageAnimatedEmoji(let emoji):
        fields["emoji"] = emoji.emoji
    case .messagePinMessage(let pin):
        fields["pinned_message_id"] = pin.messageId
    default:
        break
    }
    return fields
}
