import Foundation

/// `Moe --calendar --items-since <unix time>`: calendar events created or
/// changed since a moment, as the situations engine's items
/// (moe-home/lib/situations.py) — one JSON object per line, then
/// `{"cursor": …}`. `calendar.sh items --since <cursor>` calls it.
///
/// An invitation from someone else is the part that matters: the organiser
/// is "from", the owner being among the attendees is "to_me", and the text
/// is the whole event — title, when, where, who, and the notes an invitation
/// carries (an agenda, a question, a dial-in). A change to an event is a new
/// item (its id carries the change time), so a moved meeting is noticed.
///
/// Pure over `Event`, so it is tested without Calendar access.
enum CalendarItems {
    struct Person: Equatable {
        var name: String
        var email: String
        var isMe: Bool
        /// "pending" when the person has not answered the invitation.
        var status: String = ""
    }

    struct Event: Equatable {
        var id: String
        var thread: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String?
        var notes: String?
        var organizer: Person?
        var attendees: [Person]
        /// When it was last changed (or created); nil when EventKit has neither.
        var changed: Date?
    }

    static let textCap = 4000

    /// How far before the cursor each look re-reads: an invitation synced in
    /// with a server-side change time a little older than the last look is
    /// still read. The engine keeps an item it already has out (its id
    /// carries the change time), so the overlap is never read twice.
    static let overlap: Double = 30 * 60

    /// The items changed after `since` (less the overlap), and the new cursor:
    /// the newest change read, never "now" (an event saved while this ran is
    /// read next time) and never past `now` (a change stamped in the future
    /// by a server's clock would otherwise push every real change after it
    /// out of reach).
    static func lines(_ events: [Event], since: Double, now: Double = Date().timeIntervalSince1970,
                      zone: TimeZone = .current) -> (items: [String], cursor: Double) {
        var seen = Set<String>()
        var newest = since
        let from = since - overlap
        var rows: [(Double, String)] = []
        for e in events {
            guard let changed = e.changed?.timeIntervalSince1970, changed > from,
                  seen.insert(e.id).inserted else { continue }
            newest = max(newest, changed)
            let fromMe = e.organizer == nil || e.organizer?.isMe == true
            let invited = e.attendees.contains { $0.isMe }
            var from: [String: Any] = ["id": "me", "name": "", "me": true]
            if !fromMe, let o = e.organizer {
                from = ["id": o.email, "name": o.name, "me": false]
            }
            let obj: [String: Any] = [
                "id": "calendar/\(e.id)/\(Int(changed))",
                "thread": "calendar/\(e.thread)",
                "thread_name": String(e.title.prefix(120)),
                "at": Int(changed),
                "from": from,
                "to_me": !fromMe && invited,
                "group": e.attendees.count > 2,
                "kind": "event",
                "text": String(text(e, zone: zone).prefix(textCap)),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
               let line = String(data: data, encoding: .utf8) {
                rows.append((changed, line))
            }
        }
        return (rows.sorted { $0.0 < $1.0 }.map(\.1), max(since, min(newest, now)))
    }

    /// The whole event in words, the way a person would read an invitation.
    static func text(_ e: Event, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = e.allDay ? "EEE d MMM yyyy" : "EEE d MMM yyyy, HH:mm"
        var out = [e.title.isEmpty ? "(untitled event)" : e.title]
        out.append("When: " + f.string(from: e.start) + (e.allDay ? " (all day)" : " – " + f.string(from: e.end)))
        if let l = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { out.append("Where: " + l) }
        let others = e.attendees.filter { !$0.isMe }.map { $0.name.isEmpty ? $0.email : $0.name }
        if !others.isEmpty { out.append("With: " + others.prefix(12).joined(separator: ", ")) }
        if let me = e.attendees.first(where: \.isMe), me.status == "pending" { out.append("Your answer: not given yet") }
        if let n = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { out.append(""); out.append(n) }
        return out.joined(separator: "\n")
    }
}
