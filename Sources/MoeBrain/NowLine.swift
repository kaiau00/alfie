import Foundation

/// The one clock the model has: a line at the top of every turn saying what
/// time it is where the person is.
///
/// Ticket #9, 2026-09-23 18:08 EDT. Asked "What's up?", Moe answered "…a
/// Project Atlas call at 2 today" — four hours after it had ended. Nothing
/// the model could see said what time it was. Hermes's system prompt carries
/// only `Conversation started: Wednesday, September 23, 2026` (the date,
/// deliberately, so the prompt caches); Claude Code adds only the date; the
/// brief said `_Refreshed … 6:07 PM._` but is only re-sent when it changes,
/// so a long conversation runs on an old copy.
///
/// **In the user turn, never the system prompt.** Anything volatile in the
/// system prompt makes Hermes respawn its Claude Code child — 5–7 s a turn,
/// measured (`BrainPrompt.briefBlock`). A line on the turn costs ~90 bytes.
///
///     Now: Wednesday 23 September 2026, 6:08 PM (evening), New York time (EDT, UTC-4).
///
/// Fixed English on purpose: it is read by the model, not shown to anyone,
/// and a locale-shaped date ("mercredi 23 septembre") is one more thing for
/// it to parse. The same line is written for chat turns by the moe-screen
/// plugin (`nowline.py`), which must stay equal to this.
public enum NowLine {
    public static let prefix = "Now: "

    /// Where the day is, in words a person would use. Boundaries are the
    /// hour the part begins: 5 early morning, 8 morning, 12 afternoon,
    /// 17 evening, 21 night (and night runs on until 5).
    public static func partOfDay(hour: Int) -> String {
        switch hour {
        case 5..<8: return "early morning"
        case 8..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    /// "New York" from America/New_York, "Jerusalem" from Asia/Jerusalem,
    /// "Buenos Aires" from America/Argentina/Buenos_Aires; "UTC" for the
    /// zones that have no city.
    public static func place(of zone: TimeZone) -> String {
        let id = zone.identifier
        guard id.contains("/") else { return id == "GMT" ? "UTC" : id }
        return (id.split(separator: "/").last.map(String.init) ?? id)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// "UTC-4", "UTC+3", "UTC+5:30", "UTC".
    public static func offset(_ seconds: Int) -> String {
        if seconds == 0 { return "UTC" }
        let sign = seconds < 0 ? "-" : "+"
        let m = abs(seconds) / 60
        return m % 60 == 0 ? "UTC\(sign)\(m / 60)" : String(format: "UTC%@%d:%02d", sign, m / 60, m % 60)
    }

    /// The abbreviation (EDT, PST) for the Americas, and nil everywhere else.
    ///
    /// Only there because it is only there that Foundation and Python agree:
    /// for Asia/Jerusalem Foundation says "GMT+3" and Python "IDT", for
    /// Europe/London "GMT+1" and "BST". The chat half (nowline.py) makes the
    /// same cut, so one person reads one line on the island and on Telegram.
    static func abbreviation(_ zone: TimeZone, at date: Date) -> String? {
        let id = zone.identifier
        guard id.hasPrefix("America/") || id.hasPrefix("US/") || id == "Pacific/Honolulu",
              let a = zone.abbreviation(for: date), (2...5).contains(a.count),
              a.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return nil }
        return a
    }

    public static func line(at date: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "EEEE d MMMM yyyy, h:mm a"
        let hour = cal.component(.hour, from: date)
        let off = offset(zone.secondsFromGMT(for: date))
        let zonePart = abbreviation(zone, at: date).map { "\($0), \(off)" } ?? off
        let where_ = off == "UTC" && place(of: zone) == "UTC" ? "UTC" : "\(place(of: zone)) time (\(zonePart))"
        return "\(prefix)\(f.string(from: date)) (\(partOfDay(hour: hour))), \(where_)."
    }

    /// How old something gathered at `then` is, said against the Now line:
    /// "as of 6:07 PM, 1 min before this message". The brief's times and
    /// labels ("ended 4 h ago", "in 20 min") are relative to when it was
    /// written, and it is re-sent only when it changes — so the model is told
    /// its age rather than handed labels that silently drifted.
    public static func asOf(_ then: Date, now: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        f.dateFormat = cal.isDate(then, inSameDayAs: now) ? "h:mm a" : "EEEE d MMMM, h:mm a"
        let minutes = Int((now.timeIntervalSince(then) / 60).rounded(.down))
        let gap: String
        switch minutes {
        case ..<1: gap = "just before this message"
        case 1..<90: gap = "\(minutes) min before this message"
        default: gap = "\(Int((Double(minutes) / 60).rounded())) h before this message"
        }
        return "as of \(f.string(from: then)), \(gap)"
    }

    /// A line this file wrote, wherever it sits: "Now: <Weekday> <d> <Month>
    /// <yyyy>, <h:mm> <AM|PM> (<part>), <place>." Anchored that tightly so a
    /// person's own "Now: …" is never taken for one.
    static let written = try! NSRegularExpression(
        pattern: #"^Now: [A-Z][a-z]+day \d{1,2} [A-Z][a-z]+ \d{4}, \d{1,2}:\d{2} [AP]M \([a-z ]+\), [^\n]*\.\n*"#,
        options: [.anchorsMatchLines])

    /// `text` with the Now line as its first line. Idempotent: a turn that
    /// already carries one — a re-issued turn, a relaunch that wraps the
    /// saved turn in a note — has it replaced, never doubled, so the model
    /// never reads two clocks.
    public static func stamp(_ text: String, at date: Date, zone: TimeZone) -> String {
        let body = written.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return line(at: date, zone: zone) + "\n\n" + body
    }
}
