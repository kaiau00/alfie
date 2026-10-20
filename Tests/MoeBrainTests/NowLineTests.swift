import Foundation
import Testing
@testable import MoeBrain

/// Ticket #9: the model had no clock, and told the owner at 6:08 PM about
/// "a call at 2 today". These pin the line that is now its clock.
struct NowLineTests {
    static let ny = TimeZone(identifier: "America/New_York")!
    static let jlm = TimeZone(identifier: "Asia/Jerusalem")!

    static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// The exact turn from the ticket: 18:08 EDT on 2026-09-23.
    @Test func theTicketsMomentReadsAsTheSpecSaysItShould() {
        let line = NowLine.line(at: Self.at("2026-09-23T22:08:00Z"), zone: Self.ny)
        #expect(line == "Now: Wednesday 23 September 2026, 6:08 PM (evening), New York time (EDT, UTC-4).")
    }

    @Test func aZoneWithoutARealAbbreviationShowsOnlyTheOffset() {
        // 18:08 EDT is 01:08 the next day in Jerusalem, and it is night there.
        let line = NowLine.line(at: Self.at("2026-09-23T22:08:00Z"), zone: Self.jlm)
        #expect(line == "Now: Thursday 24 September 2026, 1:08 AM (night), Jerusalem time (UTC+3).")
    }

    @Test func halfHourZonesAndUTC() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        #expect(NowLine.line(at: Self.at("2026-09-23T06:30:00Z"), zone: kolkata)
            == "Now: Wednesday 23 September 2026, 12:00 PM (afternoon), Kolkata time (UTC+5:30).")
        #expect(NowLine.line(at: Self.at("2026-09-23T12:00:00Z"), zone: TimeZone(identifier: "UTC")!)
            == "Now: Wednesday 23 September 2026, 12:00 PM (afternoon), UTC.")
    }

    @Test func partsOfTheDay() {
        let cases: [(Int, String)] = [(0, "night"), (4, "night"), (5, "early morning"), (7, "early morning"),
                                      (8, "morning"), (11, "morning"), (12, "afternoon"), (16, "afternoon"),
                                      (17, "evening"), (20, "evening"), (21, "night"), (23, "night")]
        for (h, part) in cases { #expect(NowLine.partOfDay(hour: h) == part, "hour \(h)") }
    }

    @Test func stampingPutsTheLineFirstAndNeverTwice() {
        let now = Self.at("2026-09-23T22:08:00Z")
        let once = NowLine.stamp("What's up?", at: now, zone: Self.ny)
        #expect(once.hasPrefix("Now: Wednesday 23 September 2026, 6:08 PM"))
        #expect(once.hasSuffix("\n\nWhat's up?"))
        let later = Self.at("2026-09-23T22:30:00Z")
        let again = NowLine.stamp(once, at: later, zone: Self.ny)
        #expect(again.components(separatedBy: "Now: ").count == 2, "exactly one Now line")
        #expect(again.hasPrefix("Now: Wednesday 23 September 2026, 6:30 PM"))
        #expect(again.hasSuffix("\n\nWhat's up?"))
    }

    @Test func theBriefsAgeIsSaidAgainstNow() {
        let now = Self.at("2026-09-23T22:08:00Z")
        #expect(NowLine.asOf(Self.at("2026-09-23T22:07:00Z"), now: now, zone: Self.ny)
            == "as of 6:07 PM, 1 min before this message")
        #expect(NowLine.asOf(Self.at("2026-09-23T22:07:40Z"), now: now, zone: Self.ny)
            == "as of 6:07 PM, just before this message")
        #expect(NowLine.asOf(Self.at("2026-09-23T13:00:00Z"), now: now, zone: Self.ny)
            == "as of 9:00 AM, 9 h before this message")
        #expect(NowLine.asOf(Self.at("2026-09-22T23:00:00Z"), now: now, zone: Self.ny)
            == "as of Tuesday 22 September, 7:00 PM, 23 h before this message")
    }
}

extension NowLineTests {
    /// A relaunch wraps the saved turn — which already had a Now line — in a
    /// note. The model must see one clock, the current one.
    @Test func anOldNowLineInsideTheTextIsDropped() {
        let first = NowLine.stamp("book the table", at: Self.at("2026-09-23T22:08:00Z"), zone: Self.ny)
        let wrapped = "(Moe restarted while you were working on this.)\n\n" + first
        let restamped = NowLine.stamp(wrapped, at: Self.at("2026-09-23T22:15:00Z"), zone: Self.ny)
        #expect(restamped.components(separatedBy: "Now: ").count == 2)
        #expect(restamped.hasPrefix("Now: Wednesday 23 September 2026, 6:15 PM"))
        #expect(restamped.contains("book the table"))
    }

    /// The person's own words are never mistaken for the line.
    @Test func aPersonsOwnNowIsLeftAlone() {
        let said = "Now: can you call Dani?"
        let out = NowLine.stamp(said, at: Self.at("2026-09-23T22:08:00Z"), zone: Self.ny)
        #expect(out.hasSuffix("\n\nNow: can you call Dani?"))
    }
}

extension NowLineTests {
    /// The whole line, for six zones, from the fixture the chat half's test
    /// (test_nowline.py) reads too — so the island and Telegram say the same
    /// thing. 22:08 UTC on 2026-09-23.
    @Test func theFullLineMatchesTheSharedFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/now-lines.tsv")
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 6)
        for row in rows {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            let zone = try #require(TimeZone(identifier: parts[0]))
            #expect(NowLine.line(at: Self.at("2026-09-23T22:08:00Z"), zone: zone) == parts[1], "\(parts[0])")
        }
    }
}
