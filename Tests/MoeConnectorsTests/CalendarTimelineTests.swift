import Foundation
import Testing
@testable import MoeConnectors

/// Ticket #9. At 18:08 the brief listed a 2 PM call under "Calendar (next
/// few days)" and Moe called it "a call at 2 today". Each case below is a
/// fixed clock against one day's fixtures, and asserts the section and the
/// label every event gets.
struct CalendarTimelineTests {
    static let ny = TimeZone(identifier: "America/New_York")!
    static let jlm = TimeZone(identifier: "Asia/Jerusalem")!

    /// "2026-09-23 14:00" in `zone`.
    static func t(_ s: String, _ zone: TimeZone = ny) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    static func ev(_ title: String, _ start: String, _ end: String?, allDay: Bool = false,
                   zone: TimeZone = ny) -> EventItem {
        EventItem(start: t(start, zone), end: end.map { t($0, zone) }, title: title,
                  calendar: "Home", allDay: allDay)
    }

    /// Wednesday 23 September 2026, New York.
    static let day: [EventItem] = [
        ev("Standup", "2026-09-23 08:30", "2026-09-23 09:00"),
        ev("Project Atlas call", "2026-09-23 14:00", "2026-09-23 15:00"),
        ev("Yom Kippur", "2026-09-23 00:00", "2026-09-24 00:00", allDay: true),
        ev("Dinner", "2026-09-23 19:00", "2026-09-23 20:00"),
        ev("Party", "2026-09-23 23:30", "2026-09-24 00:30"),
        ev("Check-in", "2026-09-24 00:30", "2026-09-24 01:00"),
        ev("Call with Eli", "2026-09-24 10:00", "2026-09-24 11:00"),
        ev("Sukkot", "2026-09-25 00:00", "2026-09-26 00:00", allDay: true),
    ]

    /// Section heading → its lines, from the rendered text.
    static func sections(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current = ""
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("### ") { current = String(line.dropFirst(4)); out[current] = [] }
            else if line.hasPrefix("- ") { out[current, default: []].append(line) }
        }
        return out
    }

    static func find(_ s: [String: [String]], _ title: String) -> (section: String, line: String)? {
        for (k, lines) in s { if let l = lines.first(where: { $0.contains(" \(title)") }) { return (k, l) } }
        return nil
    }

    @Test func eightInTheMorning() throws {
        let s = Self.sections(CalendarTimeline.render(Self.day, now: Self.t("2026-09-23 08:00"), zone: Self.ny))
        #expect(s["Earlier today (over)"] == nil)
        #expect(Self.find(s, "Yom Kippur")?.section == "Now")
        #expect(Self.find(s, "Yom Kippur")?.line == "- Wed 23 Sep, all day: Yom Kippur")
        #expect(Self.find(s, "Standup")?.line == "- Wed 23 Sep, 8:30–9:00 AM Standup — today, in 30 min")
        #expect(Self.find(s, "Project Atlas call")?.line == "- Wed 23 Sep, 2:00–3:00 PM Project Atlas call — today, in 6 h")
        #expect(Self.find(s, "Project Atlas call")?.section == "Coming up")
    }

    /// The ticket's own moment.
    @Test func sixOhEightInTheEvening() throws {
        let text = CalendarTimeline.render(Self.day, now: Self.t("2026-09-23 18:08"), zone: Self.ny)
        let s = Self.sections(text)
        #expect(Self.find(s, "Project Atlas call")?.section == "Earlier today (over)")
        #expect(Self.find(s, "Project Atlas call")?.line == "- Wed 23 Sep, 2:00–3:00 PM Project Atlas call — ended 3 h ago")
        #expect(Self.find(s, "Standup")?.line == "- Wed 23 Sep, 8:30–9:00 AM Standup — ended 9 h ago")
        #expect(Self.find(s, "Yom Kippur")?.section == "Now")
        #expect(Self.find(s, "Dinner")?.line == "- Wed 23 Sep, 7:00–8:00 PM Dinner — today, in 52 min")
        #expect(Self.find(s, "Party")?.line == "- Wed 23 Sep, 11:30 PM–12:30 AM Party — today, in 5 h")
        #expect(Self.find(s, "Check-in")?.line == "- Thu 24 Sep, 12:30–1:00 AM Check-in — tomorrow")
        #expect(Self.find(s, "Call with Eli")?.line == "- Thu 24 Sep, 10:00–11:00 AM Call with Eli — tomorrow")
        #expect(Self.find(s, "Sukkot")?.line == "- Fri 25 Sep, all day: Sukkot — on Friday")
        // Order: over, now, coming — and nothing reads "12:00:00 AM".
        let over = try #require(text.range(of: "### Earlier today (over)"))
        let now = try #require(text.range(of: "### Now"))
        let coming = try #require(text.range(of: "### Coming up"))
        #expect(over.lowerBound < now.lowerBound && now.lowerBound < coming.lowerBound)
        #expect(!text.contains("12:00:00 AM"))
    }

    @Test func oneMinuteToMidnight() {
        let s = Self.sections(CalendarTimeline.render(Self.day, now: Self.t("2026-09-23 23:59"), zone: Self.ny))
        #expect(Self.find(s, "Party")?.section == "Now")
        #expect(Self.find(s, "Party")?.line == "- Wed 23 Sep, 11:30 PM–12:30 AM Party — started 29 min ago, ends in 31 min")
        #expect(Self.find(s, "Check-in")?.line == "- Thu 24 Sep, 12:30–1:00 AM Check-in — in 31 min, tomorrow")
        #expect(Self.find(s, "Dinner")?.line == "- Wed 23 Sep, 7:00–8:00 PM Dinner — ended 4 h ago")
    }

    /// Four minutes later it is a new day: yesterday's events are gone, the
    /// party that straddles midnight is still on, tomorrow became today.
    @Test func threeMinutesPastMidnight() {
        let s = Self.sections(CalendarTimeline.render(Self.day, now: Self.t("2026-09-24 00:03"), zone: Self.ny))
        #expect(Self.find(s, "Dinner") == nil)
        #expect(Self.find(s, "Yom Kippur") == nil)
        #expect(Self.find(s, "Project Atlas call") == nil)
        #expect(Self.find(s, "Party")?.line == "- Wed 23 Sep, 11:30 PM–12:30 AM Party — started 33 min ago, ends in 27 min")
        #expect(Self.find(s, "Check-in")?.line == "- Thu 24 Sep, 12:30–1:00 AM Check-in — today, in 27 min")
        #expect(Self.find(s, "Call with Eli")?.line == "- Thu 24 Sep, 10:00–11:00 AM Call with Eli — today, in 10 h")
        #expect(Self.find(s, "Sukkot")?.line == "- Fri 25 Sep, all day: Sukkot — tomorrow")
    }

    @Test func aMultiDayAllDayEventSaysWhenItEnds() {
        let trip = Self.ev("Trip", "2026-09-22 00:00", "2026-09-26 00:00", allDay: true)
        let s = Self.sections(CalendarTimeline.render([trip], now: Self.t("2026-09-23 12:00"), zone: Self.ny))
        #expect(Self.find(s, "Trip")?.line == "- Tue 22 Sep, all day: Trip — until Fri 25 Sep")
    }

    /// The same labels, worked out in Jerusalem's day, not New York's.
    @Test func aJerusalemDay() {
        let z = Self.jlm
        let items = [
            Self.ev("Shiur", "2026-09-24 09:00", "2026-09-24 10:00", zone: z),
            Self.ev("Late call", "2026-09-25 01:00", "2026-09-25 01:30", zone: z),
        ]
        let noon = Self.sections(CalendarTimeline.render(items, now: Self.t("2026-09-24 12:00", z), zone: z))
        #expect(Self.find(noon, "Shiur")?.line == "- Thu 24 Sep, 9:00–10:00 AM Shiur — ended 2 h ago")
        let late = Self.sections(CalendarTimeline.render(items, now: Self.t("2026-09-24 23:00", z), zone: z))
        #expect(Self.find(late, "Late call")?.line == "- Fri 25 Sep, 1:00–1:30 AM Late call — in 2 h, tomorrow")
        // The same instant in New York is 4 PM on the 24th: the call is today there.
        let asNY = Self.sections(CalendarTimeline.render(items, now: Self.t("2026-09-24 23:00", z), zone: Self.ny))
        #expect(Self.find(asNY, "Late call")?.line == "- Thu 24 Sep, 6:00–6:30 PM Late call — today, in 2 h")
        #expect(Self.find(asNY, "Shiur")?.line == "- Thu 24 Sep, 2:00–3:00 AM Shiur — ended 13 h ago")
    }

    /// 2026-09-30: the cloud Moe held the 29th's brief ("Wed 30 Sep, … —
    /// tomorrow") and the 30th's ("3:00–4:00 PM … — in 6 h", no date) and
    /// told the owner a meeting that was today was tomorrow. Every line now
    /// names its date, and a same-day countdown says "today" beside it.
    @Test func todaysEventsCarryTheirDate() {
        let meeting = Self.ev("Andrew Wilson Follow Up Discussion", "2026-09-30 15:00", "2026-09-30 16:00")
        let eve = Self.sections(CalendarTimeline.render([meeting], now: Self.t("2026-09-29 18:00"), zone: Self.ny))
        let morning = Self.sections(CalendarTimeline.render([meeting], now: Self.t("2026-09-30 09:00"), zone: Self.ny))
        let after = Self.sections(CalendarTimeline.render([meeting], now: Self.t("2026-09-30 17:00"), zone: Self.ny))
        #expect(Self.find(eve, "Andrew Wilson")?.line
                == "- Wed 30 Sep, 3:00–4:00 PM Andrew Wilson Follow Up Discussion — tomorrow")
        #expect(Self.find(morning, "Andrew Wilson")?.line
                == "- Wed 30 Sep, 3:00–4:00 PM Andrew Wilson Follow Up Discussion — today, in 6 h")
        #expect(Self.find(after, "Andrew Wilson")?.line
                == "- Wed 30 Sep, 3:00–4:00 PM Andrew Wilson Follow Up Discussion — ended 1 h ago")
        // Every event line in every section starts with its day.
        for s in [eve, morning, after] {
            for line in s.values.joined() { #expect(line.hasPrefix("- Wed 30 Sep, "), "\(line)") }
        }
    }

    @Test func anEmptyDaySaysSo() {
        #expect(CalendarTimeline.render([], now: Self.t("2026-09-23 12:00"), zone: Self.ny) == "Nothing scheduled.\n")
    }
}

extension CalendarTimelineTests {
    /// `--json` out, `--from-json` back in: the fixture path for the CLI.
    @Test func eventsJSONRoundTrips() throws {
        let json = ConnectorText.eventsJSON(Self.day)
        let back = try #require(ConnectorText.parseEventsJSON(Data(json.utf8)))
        #expect(back.map(\.title) == Self.day.map(\.title))
        #expect(back.map(\.allDay) == Self.day.map(\.allDay))
        #expect(back.map(\.start) == Self.day.map(\.start))
    }
}
