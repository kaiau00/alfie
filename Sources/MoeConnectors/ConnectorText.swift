import Foundation

// The text shapes the Calendar and Reminders connectors have always produced.
//
// moe-home/connectors/{calendar,reminders}.sh and tools/apple.sh used to build
// these lines in AppleScript ("tell application …"), which launches the app
// visibly every ten minutes from the sync timer. The Moe binary now reads the
// same data through EventKit (Sources/Moe/Connectors/EventKitBridge.swift)
// and prints it through this file, so the brief, the context files and the
// prompts see exactly what they saw before. Pure Foundation, no EventKit, so
// the tests can feed it fixtures.
//
// Date formats mirror AppleScript's:
//   `short date string of d`  → DateFormatter .short/.none      "8/30/26"
//   `d as string`             → DateFormatter .full/.medium     "Sunday, August 30, 2026 at 9:00:00 AM"

public struct ReminderItem: Equatable, Sendable {
    public var list: String
    public var title: String
    public var due: Date?
    public var completed: Date?

    public init(list: String, title: String, due: Date? = nil, completed: Date? = nil) {
        self.list = list; self.title = title; self.due = due; self.completed = completed
    }
}

public struct EventItem: Equatable, Sendable {
    public var start: Date
    public var end: Date?
    public var title: String
    public var calendar: String
    public var location: String?
    public var attendees: [String]
    /// The join URL, when the event has one. Carried so that "open the
    /// meeting link" is a field read rather than a screenshot and a click —
    /// see `MeetingLink`.
    public var joinURL: String?
    /// EventKit's `isAllDay`. Without it an all-day event's midnight start
    /// read as "12:00:00 AM" (Yom Kippur, ticket #9) — a time it never had.
    public var allDay: Bool

    public init(start: Date, end: Date? = nil, title: String, calendar: String,
                location: String? = nil, attendees: [String] = [],
                joinURL: String? = nil, allDay: Bool = false) {
        self.start = start; self.end = end; self.title = title; self.calendar = calendar
        self.location = location; self.attendees = attendees
        self.joinURL = joinURL
        self.allDay = allDay
    }
}

public enum ConnectorText {
    /// Which script's shape to reproduce.
    public enum Shape: String, Sendable {
        /// connectors/*.sh `pull`
        case pull
        /// connectors/*.sh `crawl` — pull plus the learn-me extras (done date,
        /// calendar name, attendees)
        case crawl
        /// tools/apple.sh — `title (due)`, `start — title`
        case apple
        /// tools/apple.sh reminders-list — bare titles
        case titles
    }

    public struct Style: Sendable {
        public var locale: Locale
        public var timeZone: TimeZone
        public init(locale: Locale = .current, timeZone: TimeZone = .current) {
            self.locale = locale; self.timeZone = timeZone
        }
    }

    // MARK: Dates

    public static func shortDate(_ d: Date, _ s: Style = Style()) -> String {
        let f = DateFormatter()
        f.locale = s.locale; f.timeZone = s.timeZone
        f.dateStyle = .short; f.timeStyle = .none
        return f.string(from: d)
    }

    public static func longDate(_ d: Date, _ s: Style = Style()) -> String {
        let f = DateFormatter()
        f.locale = s.locale; f.timeZone = s.timeZone
        f.dateStyle = .full; f.timeStyle = .medium
        return f.string(from: d)
    }

    // MARK: Reminders

    /// One line per reminder, each newline-terminated; empty string for none.
    /// (osascript printed the AppleScript's "" as a lone "\n", and added one
    /// more "\n" after a non-empty result; neither is reproduced — see the
    /// notes in EventKitBridge.swift.)
    public static func reminders(_ items: [ReminderItem], shape: Shape, style: Style = Style()) -> String {
        items.map { reminderLine($0, shape: shape, style: style) + "\n" }.joined()
    }

    public static func reminderLine(_ r: ReminderItem, shape: Shape, style: Style = Style()) -> String {
        let title = flat(r.title)
        switch shape {
        case .pull, .crawl:
            var line = "\(flat(r.list)) | \(title)"
            if let due = r.due { line += " | due " + shortDate(due, style) }
            if shape == .crawl, let done = r.completed { line += " | done " + shortDate(done, style) }
            return line
        case .apple:
            // reminders-today: `name (due date as string)`
            if let due = r.due { return "\(title) (\(longDate(due, style)))" }
            return title
        case .titles:
            return title
        }
    }

    // MARK: Events

    public static func events(_ items: [EventItem], shape: Shape, style: Style = Style()) -> String {
        items.map { eventLine($0, shape: shape, style: style) + "\n" }.joined()
    }

    public static func eventLine(_ e: EventItem, shape: Shape, style: Style = Style()) -> String {
        let start = longDate(e.start, style)
        let title = flat(e.title)
        switch shape {
        case .pull:
            var line = "\(start) | \(title)"
            if let loc = e.location.map(flat), !loc.isEmpty { line += " | " + loc }
            // Labelled, because an unlabelled URL in a pipe-delimited line
            // reads as a location and gets clicked at rather than opened.
            if let join = e.joinURL, !join.isEmpty { line += " | join: " + join }
            return line
        case .crawl:
            var line = "\(start) | \(flat(e.calendar)) | \(title)"
            if let loc = e.location.map(flat), !loc.isEmpty { line += " | " + loc }
            if let join = e.joinURL, !join.isEmpty { line += " | join: " + join }
            // The AppleScript always appended " | with:" and then one " name"
            // per attendee — including when there were none.
            line += " | with:"
            for a in e.attendees { line += " " + flat(a) }
            return line
        case .apple:
            // `--dash` is not the island's shape — its only callers are
            // `apple.sh cal-today` and `cal-next`, both of which the agent is
            // told are "your fastest route into their life". Leaving the join
            // link out of this one meant a model that took the prompt at its
            // word, ran cal-today, saw no `join:`, and concluded the data was
            // not there — falling back to the screen, which is the whole
            // failure this exists to prevent.
            var line = "\(start) — \(title)"
            if let join = e.joinURL, !join.isEmpty { line += " | join: " + join }
            return line
        case .titles:
            // Genuinely just titles; anything else here is noise.
            return "\(start) — \(title)"
        }
    }

    // MARK: JSON

    public static func remindersJSON(_ items: [ReminderItem]) -> String {
        json(items.map { r -> [String: Any] in
            var o: [String: Any] = ["list": r.list, "title": r.title]
            if let d = r.due { o["due"] = iso(d) }
            if let c = r.completed { o["completed"] = iso(c) }
            return o
        })
    }

    public static func eventsJSON(_ items: [EventItem]) -> String {
        json(items.map { e -> [String: Any] in
            var o: [String: Any] = ["start": iso(e.start), "title": e.title,
                                    "calendar": e.calendar, "attendees": e.attendees]
            if let d = e.end { o["end"] = iso(d) }
            if e.allDay { o["all_day"] = true }
            if let l = e.location, !l.isEmpty { o["location"] = l }
            if let j = e.joinURL, !j.isEmpty { o["join_url"] = j }
            return o
        })
    }

    /// The inverse of `eventsJSON`, for `Moe --calendar --brief --from-json`.
    public static func parseEventsJSON(_ data: Data) -> [EventItem]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var out: [EventItem] = []
        for r in rows {
            guard let s = r["start"] as? String, let start = f.date(from: s) else { return nil }
            out.append(EventItem(start: start, end: (r["end"] as? String).flatMap { f.date(from: $0) },
                                 title: r["title"] as? String ?? "", calendar: r["calendar"] as? String ?? "",
                                 location: r["location"] as? String,
                                 attendees: r["attendees"] as? [String] ?? [],
                                 joinURL: r["join_url"] as? String,
                                 allDay: r["all_day"] as? Bool ?? false))
        }
        return out
    }

    // MARK: Helpers

    /// A title with a newline in it would split one reminder into two lines;
    /// AppleScript's `& linefeed` had the same hole, but the context files
    /// are line-oriented, so collapse whitespace here.
    static func flat(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    static func json(_ v: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Dates the write paths accept: ISO 8601 (with or without seconds or a
    /// zone), or apple.sh's `2026-09-01 09:00`, or a bare `2026-09-01`.
    public static func parseDate(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for opts in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] as [ISO8601DateFormatter.Options] {
            iso.formatOptions = opts
            if let d = iso.date(from: t) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}
