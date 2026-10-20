import Foundation
import Testing
@testable import Moe

/// `Moe --calendar --items-since`: calendar changes as the situations
/// engine's items (Sources/Moe/Connectors/CalendarItems.swift).
///
/// Falsifiers: move the cursor to "now" (an event saved during the read is
/// never seen), drop the notes (an invitation's agenda is the point), call
/// the owner's own event "to_me", or emit one item per occurrence of a
/// recurring meeting — each turns a test red.
@Suite("Calendar › items for the situations engine")
struct CalendarItemsTests {
    let me = CalendarItems.Person(name: "Izzy", email: "izzy@example.com", isMe: true, status: "pending")
    let dana = CalendarItems.Person(name: "Dana Cohen", email: "dana@acme.com", isMe: false)

    func event(_ id: String, changed: Double?, organizer: CalendarItems.Person?,
               attendees: [CalendarItems.Person], notes: String? = nil) -> CalendarItems.Event {
        .init(id: id, thread: "T-" + id, title: "Budget review", start: Date(timeIntervalSince1970: 1_790_100_000),
              end: Date(timeIntervalSince1970: 1_790_103_600), allDay: false, location: "Room 4",
              notes: notes, organizer: organizer, attendees: attendees,
              changed: changed.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func anInvitationIsFromItsOrganiserToMeWithTheWholeText() throws {
        let out = CalendarItems.lines([event("e1", changed: 1_790_000_500, organizer: dana, attendees: [dana, me],
                                             notes: "Bring the Q3 numbers — we need to decide on the $40k cut.")],
                                      since: 1_790_000_000, now: 1_790_001_000, zone: TimeZone(identifier: "UTC")!)
        #expect(out.cursor == 1_790_000_500)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.items[0].utf8)) as? [String: Any])
        #expect(obj["id"] as? String == "calendar/e1/1790000500")
        #expect(obj["thread"] as? String == "calendar/T-e1")
        #expect(obj["to_me"] as? Bool == true)
        #expect((obj["from"] as? [String: Any])?["name"] as? String == "Dana Cohen")
        #expect(obj["kind"] as? String == "event")
        let text = obj["text"] as? String ?? ""
        #expect(text.contains("Bring the Q3 numbers — we need to decide on the $40k cut."))
        #expect(text.contains("Where: Room 4"))
        #expect(text.contains("With: Dana Cohen"))
        #expect(text.contains("Your answer: not given yet"))
        #expect(text.contains("When: Tue 22 Sep 2026, 18:00 – Tue 22 Sep 2026, 19:00"))
    }

    @Test func myOwnEventIsFromMeAndNotAddressedToMe() throws {
        let out = CalendarItems.lines([event("e2", changed: 1_790_000_100, organizer: nil, attendees: [])],
                                      since: 1_790_000_000, now: 1_790_001_000)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.items[0].utf8)) as? [String: Any])
        #expect((obj["from"] as? [String: Any])?["me"] as? Bool == true)
        #expect(obj["to_me"] as? Bool == false)
    }

    @Test func onlyChangesAfterTheCursorAndOneItemPerEvent() {
        let events = [event("old", changed: 1_789_990_000, organizer: dana, attendees: [me]),
                      event("rec", changed: 1_790_000_200, organizer: dana, attendees: [me]),
                      event("rec", changed: 1_790_000_200, organizer: dana, attendees: [me]),
                      event("none", changed: nil, organizer: dana, attendees: [me])]
        let out = CalendarItems.lines(events, since: 1_790_000_000, now: 1_790_001_000)
        #expect(out.items.count == 1)
        #expect(out.cursor == 1_790_000_200)
        #expect(CalendarItems.lines([], since: 42).cursor == 42)
    }

    @Test func aFutureChangeTimeNeverPushesTheCursorPastNow() {
        let out = CalendarItems.lines([event("skew", changed: 1_790_900_000, organizer: dana, attendees: [me])],
                                      since: 1_790_000_000, now: 1_790_001_000)
        #expect(out.items.count == 1)
        #expect(out.cursor == 1_790_001_000)
    }

    @Test func aChangeJustBeforeTheCursorIsStillRead() {
        let out = CalendarItems.lines([event("late", changed: 1_789_999_000, organizer: dana, attendees: [me])],
                                      since: 1_790_000_000, now: 1_790_001_000)
        #expect(out.items.count == 1)
        #expect(out.cursor == 1_790_000_000)
    }
}
