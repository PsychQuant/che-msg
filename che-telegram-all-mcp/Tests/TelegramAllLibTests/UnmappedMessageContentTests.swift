import XCTest
import TDLibKit
@testable import TelegramAllLib

/// The fields of a message whose content `messageToDict` does not map (PsychQuant/che-msg#117):
/// every such message says which TDLib content it is, and seven kinds also say what is in it.
/// Synthetic values only.
final class UnmappedMessageContentTests: XCTestCase {
    private let contact = MessageContent.messageContact(MessageContact(contact: Contact(
        firstName: "Ann", lastName: "Lee", phoneNumber: "+15550100", userId: 42, vcard: "BEGIN:VCARD")))
    private let dice = MessageContent.messageDice(MessageDice(
        emoji: "🎲", finalState: nil, initialState: nil, successAnimationFrameNumber: 0, value: 5))
    private let call = MessageContent.messageCall(MessageCall(
        discardReason: .callDiscardReasonMissed, duration: 0, isVideo: true))
    private let story = MessageContent.messageStory(MessageStory(storyId: 7, storyPosterChatId: -1001, viaMention: false))
    private let venue = MessageContent.messageVenue(MessageVenue(venue: Venue(
        address: "1 Main St", id: "v1", location: Location(horizontalAccuracy: 0, latitude: 25.03, longitude: 121.56),
        provider: "foursquare", title: "Cafe", type: "")))
    private let animatedEmoji = MessageContent.messageAnimatedEmoji(MessageAnimatedEmoji(
        animatedEmoji: AnimatedEmoji(fitzpatrickType: 0, sound: nil, sticker: nil, stickerHeight: 0, stickerWidth: 0),
        emoji: "❤️"))
    private let pin = MessageContent.messagePinMessage(MessagePinMessage(messageId: 5_242_880))

    // MARK: content_type

    func testEveryUnmappedMessageNamesItsTDLibContentType() {
        XCTAssertEqual(unmappedContentFields(contact)["content_type"] as? String, "messageContact")
        XCTAssertEqual(unmappedContentFields(story)["content_type"] as? String, "messageStory")
        XCTAssertEqual(unmappedContentFields(.messageScreenshotTaken)["content_type"] as? String,
                       "messageScreenshotTaken")
        XCTAssertEqual(unmappedContentFields(.messageUnsupported)["content_type"] as? String, "messageUnsupported")
    }

    /// The name is the one TDLib itself uses: TDLibKit's own JSON encoding writes it as the
    /// value's type discriminator.
    func testConstructorNameMatchesTDLibKitsEncoding() throws {
        let samples: [MessageContent] = [contact, dice, call, story, venue, animatedEmoji, pin,
                                         .messageExpiredPhoto, .messageUnsupported, .messageContactRegistered]
        for content in samples {
            let data = try JSONEncoder().encode(content)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(tdlibConstructorName(content), object["@type"] as? String)
        }
        let reason = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CallDiscardReason.callDiscardReasonHungUp))
        XCTAssertEqual(tdlibConstructorName(CallDiscardReason.callDiscardReasonHungUp),
                       (reason as? [String: Any])?["@type"] as? String)
    }

    /// Never `type`: the caller has already decided that it is "other".
    func testFieldsNeverSetType() {
        for content in [contact, dice, call, story, venue, animatedEmoji, pin, .messageExpiredVideo] {
            XCTAssertNil(unmappedContentFields(content)["type"], "\(content)")
        }
    }

    // MARK: Readable fields, one kind each

    func testContactGivesNameAndUserIdButNotPhoneOrVCard() {
        let fields = unmappedContentFields(contact)
        XCTAssertEqual(fields["contact_name"] as? String, "Ann Lee")
        XCTAssertEqual(fields["contact_user_id"] as? Int64, 42)
        XCTAssertFalse(fields.values.contains { "\($0)".contains("+15550100") || "\($0)".contains("VCARD") })
    }

    func testContactWithoutAccountOrLastNameOmitsThem() {
        let fields = unmappedContentFields(.messageContact(MessageContact(contact: Contact(
            firstName: "Ann", lastName: "", phoneNumber: "", userId: 0, vcard: ""))))
        XCTAssertEqual(fields["contact_name"] as? String, "Ann")
        XCTAssertNil(fields["contact_user_id"])
    }

    func testDiceGivesEmojiAndValue() {
        let fields = unmappedContentFields(dice)
        XCTAssertEqual(fields["emoji"] as? String, "🎲")
        XCTAssertEqual(fields["value"] as? Int, 5)
    }

    func testCallGivesDurationVideoAndDiscardReason() {
        let fields = unmappedContentFields(call)
        XCTAssertEqual(fields["duration"] as? Int, 0)
        XCTAssertEqual(fields["is_video"] as? Bool, true)
        XCTAssertEqual(fields["discard_reason"] as? String, "callDiscardReasonMissed")
    }

    func testStoryGivesPosterAndId() {
        let fields = unmappedContentFields(story)
        XCTAssertEqual(fields["story_poster_chat_id"] as? Int64, -1001)
        XCTAssertEqual(fields["story_id"] as? Int, 7)
        XCTAssertEqual(fields["via_mention"] as? Bool, false)
    }

    func testVenueGivesTitleAddressAndCoordinates() {
        let fields = unmappedContentFields(venue)
        XCTAssertEqual(fields["title"] as? String, "Cafe")
        XCTAssertEqual(fields["address"] as? String, "1 Main St")
        XCTAssertEqual(fields["latitude"] as? Double, 25.03)
        XCTAssertEqual(fields["longitude"] as? Double, 121.56)
    }

    func testAnimatedEmojiGivesEmoji() {
        XCTAssertEqual(unmappedContentFields(animatedEmoji)["emoji"] as? String, "❤️")
    }

    func testPinGivesPinnedMessageId() {
        XCTAssertEqual(unmappedContentFields(pin)["pinned_message_id"] as? Int64, 5_242_880)
    }

    /// A kind outside the seven says what it is and nothing more.
    func testOtherKindsGiveOnlyTheContentType() {
        let fields = unmappedContentFields(.messageExpiredPhoto)
        XCTAssertEqual(Set(fields.keys), ["content_type"])
    }

    /// The fields serialize as JSON, as `messageToDict`'s result must.
    func testFieldsAreValidJSON() {
        for content in [contact, dice, call, story, venue, animatedEmoji, pin, .messageUnsupported] {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(unmappedContentFields(content)), "\(content)")
        }
    }
}
