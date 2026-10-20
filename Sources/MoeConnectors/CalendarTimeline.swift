import Foundation

/// The brief's calendar, split by the clock (ticket #9).
///
/// At 18:08 on 2026-09-23 the brief's "Calendar (next few days)" still held
/// the 2 PM call: the window started at midnight, and each line carried only
/// a start — no end, no all-day mark (Yom Kippur read "12:00:00 AM") and
/// nothing to say it was over. Moe read it out as "a call at 2 today".
///
/// So the brief writes three sections instead, each line with its end and a
/// label relative to when it was written:
///
///     ### Earlier today (over)
///     - Wed 23 Sep, 2:00–3:00 PM Project Atlas call — ended 3 h ago
///
///     ### Now
///     - Wed 23 Sep, all day: Yom Kippur
///
///     ### Coming up
///     - Thu 24 Sep, 10:00–11:00 AM Standup — tomorrow
///
/// The labels are as of `now` — the brief's own stamp. The brief can be read
/// a while after it was written, which is why the turn that carries it says
/// its age (`BrainPrompt.dated`) and why the Now line on every turn is the
/// clock the model is told to trust.
///
/// Fixed English, like the Now line: the model reads this, not a person.
/// `context/calendar.md` itself is unchanged — four readers parse its lines
/// (the heads-up job, the away schedule, nudge.sh, the ledger's
/// `context/calendar` document) and none of them wants this shape.
public enum CalendarTimeline {

    public static func render(_ items: [EventItem], now: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let midnight = cal.startOfDay(for: now)
        var over: [String] = [], current: [String] = [], coming: [String] = []
        // By day, all-day first within a day, then by start.
        let key = { (e: EventItem) in (cal.startOfDay(for: e.start), e.allDay ? 0 : 1, e.start) }
        for e in items.sorted(by: { key($0) < key($1) }) {
            let end = e.end ?? e.start
            if e.start > now {
                coming.append(line(e, now: now, cal: cal, label: upcoming(e.start, now: now, cal: cal)))
            } else if end > now || (e.allDay && cal.isDate(e.start, inSameDayAs: now)) {
                current.append(line(e, now: now, cal: cal, label: ongoing(e, now: now, cal: cal)))
            } else if end > midnight {
                let label = now.timeIntervalSince(end) < 60 ? "just ended" : "ended \(span(now.timeIntervalSince(end))) ago"
                over.append(line(e, now: now, cal: cal, label: label))
            }
            // Anything that ended before today is not in the brief at all.
        }
        var out: [String] = []
        if !over.isEmpty { out += ["### Earlier today (over)", ""] + over + [""] }
        if !current.isEmpty { out += ["### Now", ""] + current + [""] }
        if !coming.isEmpty { out += ["### Coming up", ""] + coming + [""] }
        if out.isEmpty { return "Nothing scheduled.\n" }
        return out.joined(separator: "\n")
    }

    // MARK: Lines

    static func line(_ e: EventItem, now: Date, cal: Calendar, label: String?) -> String {
        // Every line names its day, today's included (2026-09-30): the brief
        // is read hours later, on another machine, beside yesterday's copy.
        // "3:00–4:00 PM … — in 6 h" with no date, next to the day before's
        // "Wed 30 Sep, 3:00–4:00 PM … — tomorrow", let the cloud Moe tell the
        // owner a meeting that was today was tomorrow. A relative label is
        // only as good as the clock it was written against; the date is not.
        let day = dayName(e.start, cal) + ", "
        let when = day + (e.allDay ? "all day:" : times(e.start, e.end, cal))
        var text = "- \(when) \(ConnectorText.flat(e.title))"
        if let loc = e.location.map(ConnectorText.flat), !loc.isEmpty { text += " | " + loc }
        if let join = e.joinURL, !join.isEmpty { text += " | join: " + join }
        if let label, !label.isEmpty { text += " — " + label }
        return text
    }

    /// "2:00–3:00 PM", "11:30 AM–12:30 PM", "9:00 AM" when there is no end.
    static func times(_ start: Date, _ end: Date?, _ cal: Calendar) -> String {
        let f = formatter("h:mm a", cal)
        let s = f.string(from: start)
        guard let end, end > start else { return s }
        let e = f.string(from: end)
        if s.suffix(2) == e.suffix(2), cal.isDate(start, inSameDayAs: end) {
            return String(s.dropLast(3)) + "–" + e
        }
        return s + "–" + e
    }

    static func dayName(_ d: Date, _ cal: Calendar) -> String {
        formatter("EEE d MMM", cal).string(from: d)
    }

    static func formatter(_ format: String, _ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = format
        return f
    }

    // MARK: Labels

    static func ongoing(_ e: EventItem, now: Date, cal: Calendar) -> String? {
        if e.allDay {
            // EventKit ends an all-day event at the next midnight; the last
            // day it covers is the one before its end.
            guard let end = e.end, let last = cal.date(byAdding: .second, value: -1, to: end),
                  !cal.isDate(last, inSameDayAs: now) else { return nil }
            return "until \(dayName(last, cal))"
        }
        let began = now.timeIntervalSince(e.start)
        let started = began < 60 ? "started just now" : "started \(span(began)) ago"
        guard let end = e.end else { return started }
        return started + ", ends in " + span(end.timeIntervalSince(now))
    }

    static func upcoming(_ start: Date, now: Date, cal: Calendar) -> String {
        let away = start.timeIntervalSince(now)
        let today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: start)).day ?? 0
        switch days {
        case ..<1:
            return "today, in " + span(away)
        case 1:
            // Just past midnight is "in 31 min", not a day away.
            return away < 3 * 3600 ? "in \(span(away)), tomorrow" : "tomorrow"
        case 2..<7:
            return "on " + formatter("EEEE", cal).string(from: start)
        default:
            return "in \(days) days"
        }
    }

    /// "20 min", "1 h 20 min", "3 h".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 120 { return minutes == 60 ? "1 h" : "1 h \(minutes - 60) min" }
        return "\(Int((Double(minutes) / 60).rounded())) h"
    }
}
