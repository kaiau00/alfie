import Foundation
import Testing
@testable import MoeConnectors

/// The line shapes calendar.sh / reminders.sh / apple.sh produced through
/// AppleScript, now produced from EventKit data. Locale and zone are pinned
/// so the expected strings hold on any machine.
struct ConnectorTextTests {
    let style = ConnectorText.Style(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/New_York")!)

    // 2026-08-30 09:00 New York
    let t0 = Date(timeIntervalSince1970: 1_788_094_800)

    /// macOS puts a narrow no-break space (U+202F) before AM/PM; AppleScript's
    /// `as string` does the same, so the formatter keeps it. Plain space here
    /// so the expected strings can be typed.
    func n(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func remindersPullShape() {
        let items = [
            ReminderItem(list: "Home", title: "Buy milk"),
            ReminderItem(list: "Work", title: "Send invoice", due: t0, completed: t0),
        ]
        let out = ConnectorText.reminders(items, shape: .pull, style: style)
        #expect(out == "Home | Buy milk\nWork | Send invoice | due 8/30/26\n")
    }

    @Test func remindersCrawlAddsDone() {
        let r = ReminderItem(list: "Work", title: "Send invoice", due: t0, completed: t0)
        #expect(ConnectorText.reminderLine(r, shape: .crawl, style: style)
                == "Work | Send invoice | due 8/30/26 | done 8/30/26")
    }

    @Test func remindersAppleShapes() {
        let r = ReminderItem(list: "Work", title: "Call Dana", due: t0)
        #expect(n(ConnectorText.reminderLine(r, shape: .apple, style: style))
                == "Call Dana (Sunday, August 30, 2026 at 9:00:00 AM)")
        #expect(ConnectorText.reminderLine(r, shape: .titles, style: style) == "Call Dana")
    }

    @Test func eventsPullShape() {
        let e = EventItem(start: t0, title: "Standup", calendar: "Work", location: "Room 4")
        #expect(n(ConnectorText.eventLine(e, shape: .pull, style: style))
                == "Sunday, August 30, 2026 at 9:00:00 AM | Standup | Room 4")
        let noLoc = EventItem(start: t0, title: "Standup", calendar: "Work", location: "")
        #expect(n(ConnectorText.eventLine(noLoc, shape: .pull, style: style))
                == "Sunday, August 30, 2026 at 9:00:00 AM | Standup")
    }

    @Test func eventsCrawlAlwaysHasWith() {
        let e = EventItem(start: t0, title: "Standup", calendar: "Work", attendees: ["Ann", "Bob"])
        #expect(n(ConnectorText.eventLine(e, shape: .crawl, style: style))
                == "Sunday, August 30, 2026 at 9:00:00 AM | Work | Standup | with: Ann Bob")
        let alone = EventItem(start: t0, title: "Focus", calendar: "Home")
        #expect(ConnectorText.eventLine(alone, shape: .crawl, style: style).hasSuffix(" | Home | Focus | with:"))
    }

    @Test func eventsAppleShape() {
        let e = EventItem(start: t0, title: "Standup", calendar: "Work")
        #expect(n(ConnectorText.eventLine(e, shape: .apple, style: style))
                == "Sunday, August 30, 2026 at 9:00:00 AM — Standup")
    }

    @Test func emptyIsEmpty() {
        #expect(ConnectorText.reminders([], shape: .pull, style: style) == "")
        #expect(ConnectorText.events([], shape: .crawl, style: style) == "")
    }

    @Test func newlinesInTitlesStayOnOneLine() {
        let r = ReminderItem(list: "L", title: "two\nlines")
        #expect(ConnectorText.reminderLine(r, shape: .pull, style: style) == "L | two lines")
    }

    @Test func jsonIsParseable() throws {
        let out = ConnectorText.eventsJSON([EventItem(start: t0, title: "S", calendar: "C", attendees: ["A"])])
        let arr = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        #expect(arr.count == 1 && arr[0]["title"] as? String == "S")
        #expect((arr[0]["attendees"] as? [String]) == ["A"])
    }

    // 2026-08-30 00:00 New York — what EventKit (and the AppleScript's
    // `start date`) give for an all-day event
    let midnight = Date(timeIntervalSince1970: 1_788_062_400)

    @Test func allDayEventPrintsMidnightLikeAppleScriptDid() {
        let e = EventItem(start: midnight, title: "Bank holiday", calendar: "Home")
        #expect(n(ConnectorText.eventLine(e, shape: .pull, style: style))
                == "Sunday, August 30, 2026 at 12:00:00 AM | Bank holiday")
        #expect(n(ConnectorText.eventLine(e, shape: .crawl, style: style))
                == "Sunday, August 30, 2026 at 12:00:00 AM | Home | Bank holiday | with:")
    }

    @Test func reminderWithoutDueDateHasNoDueField() {
        let r = ReminderItem(list: "Home", title: "Fix the gate")
        #expect(ConnectorText.reminderLine(r, shape: .pull, style: style) == "Home | Fix the gate")
        #expect(ConnectorText.reminderLine(r, shape: .crawl, style: style) == "Home | Fix the gate")
        #expect(ConnectorText.reminderLine(r, shape: .apple, style: style) == "Fix the gate")
        #expect(ConnectorText.reminderLine(r, shape: .titles, style: style) == "Fix the gate")
    }

    @Test func crawlDoneWithoutDue() {
        let r = ReminderItem(list: "Work", title: "Ship it", completed: t0)
        #expect(ConnectorText.reminderLine(r, shape: .crawl, style: style) == "Work | Ship it | done 8/30/26")
        // pull never shows completion, even when handed one
        #expect(ConnectorText.reminderLine(r, shape: .pull, style: style) == "Work | Ship it")
    }

    @Test func pullNeverShowsCalendarOrAttendees() {
        let e = EventItem(start: t0, title: "Standup", calendar: "Work", attendees: ["Ann"])
        #expect(!ConnectorText.eventLine(e, shape: .pull, style: style).contains("Work"))
        #expect(!ConnectorText.eventLine(e, shape: .pull, style: style).contains("with:"))
    }

    @Test func whitespaceOnlyLocationIsDropped() {
        let e = EventItem(start: t0, title: "Standup", calendar: "Work", location: "\n\t")
        #expect(n(ConnectorText.eventLine(e, shape: .pull, style: style))
                == "Sunday, August 30, 2026 at 9:00:00 AM | Standup")
    }

    @Test func pipesInTitlesAreLeftAlone() {
        // AppleScript did not escape them either; the readers split on " | ".
        let r = ReminderItem(list: "L", title: "a | b")
        #expect(ConnectorText.reminderLine(r, shape: .pull, style: style) == "L | a | b")
    }

    @Test func jsonOmitsMissingFields() throws {
        let out = ConnectorText.remindersJSON([ReminderItem(list: "L", title: "T")])
        let arr = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        #expect(arr[0]["due"] == nil && arr[0]["completed"] == nil)
        #expect(ConnectorText.remindersJSON([]) == "[]")
    }

    @Test func parseDateForms() {
        let tz = TimeZone(identifier: "America/New_York")!
        #expect(ConnectorText.parseDate("2026-08-30 09:00", timeZone: tz) == t0)
        #expect(ConnectorText.parseDate("2026-08-30T09:00:00", timeZone: tz) == t0)
        #expect(ConnectorText.parseDate("2026-08-30T13:00:00Z", timeZone: tz) == t0)
        #expect(ConnectorText.parseDate("2026-08-30", timeZone: tz) != nil)
        #expect(ConnectorText.parseDate("next tuesday") == nil)
    }
}
