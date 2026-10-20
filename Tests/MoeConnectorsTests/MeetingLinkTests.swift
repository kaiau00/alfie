import Foundation
import Testing
@testable import MoeConnectors

/// The join link is data. These tests are the reason it never has to be a
/// screenshot and a click again.
struct MeetingLinkTests {

    // MARK: The incident

    @Test func theOutlookInviteFromTheIncidentYieldsItsTeamsLink() {
        // Outlook's shape: a webmail permalink on `url`, the real join link
        // buried in notes under a wall of boilerplate. The recognised host
        // must win wherever it was found.
        let notes = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        <https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC123%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d>
        Meeting ID: 123 456 789
        Learn more about Teams | Meeting options
        """
        #expect(MeetingLink.find(url: "https://outlook.office365.com/calendar/item/xyz",
                             location: "Microsoft Teams Meeting",
                             notes: notes) == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC123%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d")
    }

    @Test func aGoogleMeetLinkInTheLocationField() {
        #expect(MeetingLink.find(location: "https://meet.google.com/abc-defg-hij") == "https://meet.google.com/abc-defg-hij")
    }

    @Test func theUrlFieldIsPreferredWhenItIsItselfAJoinLink() {
        #expect(MeetingLink.find(url: "https://zoom.us/j/123",
                             notes: "backup: https://meet.google.com/x") == "https://zoom.us/j/123")
    }

    // MARK: Ranking

    @Test func aRecognisedHostBeatsAnUnrecognisedOneEvenFromALaterField() {
        #expect(MeetingLink.find(url: "https://intranet.example.com/event/9",
                             notes: "https://zoom.us/j/55") == "https://zoom.us/j/55")
    }

    @Test func teamsBeatsDiscordOnAnEventCarryingBoth() {
        #expect(MeetingLink.find(notes: "https://discord.gg/xyz and https://teams.microsoft.com/l/meetup-join/1") == "https://teams.microsoft.com/l/meetup-join/1")
    }

    // MARK: What must NOT be treated as a join link

    @Test func aPathThatMerelyMentionsAJoinHostIsNotOne() {
        // Host-only matching: a page about Zoom is not a Zoom meeting.
        #expect(!(MeetingLink.isJoinLink("https://evil.example.com/zoom.us/j/1")))
        #expect(MeetingLink.find(notes: "https://evil.example.com/zoom.us/j/1") == nil)
    }

    @Test func subdomainsOfARecognisedHostStillCount() {
        #expect(MeetingLink.isJoinLink("https://acme.zoom.us/j/123"))
    }

    @Test func aBareLinkLooseInNotesIsNotAssumedToBeTheMeeting() {
        // Notes are full of links to unrelated things; guessing here is how
        // you open the agenda doc instead of joining the call.
        #expect(MeetingLink.find(notes: "agenda: https://docs.example.com/q3") == nil)
    }

    @Test func anUnrecognisedUrlFieldIsStillOfferedAsALastResort() {
        // The organiser put it on the event on purpose.
        #expect(MeetingLink.find(url: "https://meet.acme-internal.dev/room/7") == "https://meet.acme-internal.dev/room/7")
    }

    @Test func anEventWithNothingHasNoLink() {
        #expect(MeetingLink.find() == nil)
        #expect(MeetingLink.find(url: "", location: "", notes: "") == nil)
        #expect(MeetingLink.find(location: "Conference room B") == nil)
    }

    @Test func aMailtoUrlIsNotAJoinLink() {
        #expect(MeetingLink.find(url: "mailto:miriam@example.com") == nil)
    }

    // MARK: Parsing robustness

    @Test func trailingPunctuationIsStrippedButQueryStringsSurvive() {
        #expect(MeetingLink.find(notes: "Join here: https://zoom.us/j/9?pwd=a.b_c-d.") == "https://zoom.us/j/9?pwd=a.b_c-d")
        #expect(MeetingLink.find(notes: "(https://meet.google.com/a-b-c)") == "https://meet.google.com/a-b-c")
    }

    @Test func angleBracketAndQuoteWrappedLinksAreFound() {
        #expect(MeetingLink.find(notes: "<https://zoom.us/j/1>") == "https://zoom.us/j/1")
        #expect(MeetingLink.find(notes: "href=\"https://zoom.us/j/2\"") == "https://zoom.us/j/2")
    }

    @Test func aBareSchemeIsNotAUrl() {
        #expect(MeetingLink.find(notes: "https:// and http://") == nil)
    }

    // MARK: It reaches the renderers the agent actually reads

    func event(joinURL: String?) -> EventItem {
        EventItem(start: Date(timeIntervalSince1970: 1_788_442_200),
                  title: "Pulse access", calendar: "Work",
                  attendees: ["Miriam"], joinURL: joinURL)
    }

    @Test func pullAndCrawlLinesLabelTheLink() {
        for shape in [ConnectorText.Shape.pull, .crawl] {
            let line = ConnectorText.eventLine(event(joinURL: "https://teams.microsoft.com/l/1"),
                                               shape: shape)
            #expect(line.contains("join: https://teams.microsoft.com/l/1"), "\(shape) line must carry a labelled join link: \(line)")
        }
    }

    @Test func anEventWithoutALinkGainsNoEmptyField() {
        let line = ConnectorText.eventLine(event(joinURL: nil), shape: .pull)
        #expect(!(line.contains("join:")))
    }

    @Test func jSONCarriesJoinURL() {
        let out = ConnectorText.eventsJSON([event(joinURL: "https://zoom.us/j/7")])
        #expect(out.contains("\"join_url\""))
        // JSONSerialization escapes forward slashes, so the raw URL does not
        // appear literally — assert the escaped form the connector really emits.
        #expect(out.contains("zoom.us"))
        #expect(out.replacingOccurrences(of: "\\/", with: "/")
                   .contains("https://zoom.us/j/7"))
        #expect(!(ConnectorText.eventsJSON([event(joinURL: nil)]).contains("join_url")))
    }

    // MARK: Hostile and malformed input (each of these was a review finding)

    @Test func htmlEntitiesInAnOutlookBodyAreDecoded() {
        // A real Outlook invite is HTML-derived: ?context=…&amp;anon=true.
        // Left encoded the link looks valid and opens to an error, which is
        // worse than no link — the failure shows up in the browser, not here.
        #expect(MeetingLink.find(notes: "href=\"https://teams.microsoft.com/l/x?a=1&amp;b=2\"")
                == "https://teams.microsoft.com/l/x?a=1&b=2")
        #expect(MeetingLink.find(notes: "https://zoom.us/j/1&nbsp;more")
                == "https://zoom.us/j/1")
    }

    @Test func twoUrlsGluedByACommaAreSeparated() {
        #expect(MeetingLink.find(notes: "https://zoom.us/j/1,https://meet.google.com/x")
                == "https://zoom.us/j/1")
    }

    @Test func aBackslashInTheAuthorityIsRefused() {
        // Foundation reads the host as zoom.us; Chrome and Safari follow the
        // WHATWG rule, treat "\\" as "/", and go to evil.com.
        #expect(!(MeetingLink.isJoinLink("https://evil.com\\@zoom.us/")))
        #expect(MeetingLink.find(url: "https://evil.com\\@zoom.us/") == nil)
    }

    @Test func userinfoIsRefusedEvenWhenTheHostLooksRight() {
        #expect(!(MeetingLink.isJoinLink("https://user@zoom.us.evil.com/")))
        #expect(!(MeetingLink.isJoinLink("https://zoom.us@evil.com/")))
        #expect(!(MeetingLink.isJoinLink("https://zoom.us:443@evil.com/")))
    }

    @Test func lookalikeHostsAreRefused() {
        for bad in ["https://zoom.us.evil.com/x", "https://evil.com?u=zoom.us",
                    "https://notzoom.us/j/1", "https://zoom.us%2Eevil.com/"] {
            #expect(!(MeetingLink.isJoinLink(bad)), "must not accept \(bad)")
        }
    }

    @Test func aTrailingRootDotIsStillTheSameHost() {
        #expect(MeetingLink.isJoinLink("https://zoom.us./j/1"))
    }

    @Test func schemeMatchingIsCaseInsensitive() {
        #expect(MeetingLink.find(notes: "HTTPS://ZOOM.US/j/1") == "HTTPS://ZOOM.US/j/1")
    }

    @Test func aSchemeThatMerelyStartsWithHttpIsNotAUrl() {
        #expect(MeetingLink.find(url: "httpfoo://evil.com/x") == nil)
        #expect(MeetingLink.find(url: "javascript:alert(1)") == nil)
        #expect(MeetingLink.find(url: "file:///etc/passwd") == nil)
    }

    @Test func anAbsurdlyLongUrlIsRefused() {
        // It would otherwise land in the daily brief, which is re-sent on
        // every turn.
        let huge = "https://zoom.us/j/" + String(repeating: "a", count: 5000)
        #expect(MeetingLink.find(url: huge) == nil)
        #expect(MeetingLink.find(notes: huge) == nil)
    }

    @Test func anUnrecognisedUrlFieldIsOfferedOnPurpose() {
        // Deliberate, and named here so nobody "fixes" it later by accident:
        // a company's internal meeting host will never be in `hosts`, and the
        // organiser put this on the event. It must still be a real http(s)
        // URL with no host ambiguity.
        #expect(MeetingLink.find(url: "https://meet.acme-internal.dev/room/7")
                == "https://meet.acme-internal.dev/room/7")
    }

    // MARK: Every agent-visible calendar shape carries it

    @Test func theDashShapeAlsoCarriesTheLink() {
        // `--dash` is what `apple.sh cal-today` and `cal-next` run, and the
        // system prompt calls apple.sh "your fastest route into their life".
        // A model that ran it and saw no `join:` would conclude the data was
        // not there and fall back to the screen.
        let line = ConnectorText.eventLine(event(joinURL: "https://zoom.us/j/7"),
                                           shape: .apple)
        #expect(line.contains("join: https://zoom.us/j/7"), "\(line)")
    }

    @Test func theTitlesShapeStaysBare() {
        let line = ConnectorText.eventLine(event(joinURL: "https://zoom.us/j/7"),
                                           shape: .titles)
        #expect(!(line.contains("join:")))
    }

    @Test func theJoinFieldComesLastSoPipeSlicersStayCorrect() {
        // The heads-up job slices on "|" and treats the tail as the location.
        let e = EventItem(start: Date(timeIntervalSince1970: 1_788_442_200),
                          title: "Pulse access", calendar: "Work",
                          location: "Room 4", attendees: ["Miriam"],
                          joinURL: "https://zoom.us/j/7")
        let parts = ConnectorText.eventLine(e, shape: .pull)
            .components(separatedBy: " | ")
        #expect(parts.last!.hasPrefix("join: "))
        #expect(parts[parts.count - 2] == "Room 4")
    }
}
