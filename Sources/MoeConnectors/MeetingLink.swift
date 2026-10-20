import Foundation

/// Finding the "join" URL on a calendar event, without looking at the screen.
///
/// On 2026-09-03 someone asked Moe to open the meeting link with Miriam. The
/// event was right there in Calendar with a Teams URL on it, but `EventItem`
/// carried only start/end/title/calendar/location/attendees — no URL, no notes
/// — so the agent could not see the link in the data it had been handed. It
/// went looking in Gmail instead (a `gmail_pull`, a `gmail_crawl`, then five
/// greps over the crawl's own result file), and when that failed it fell back
/// to driving the GUI: open Calendar, screenshot it, click the link by
/// coordinate. Eleven tool calls before the first click, and the click was
/// never needed.
///
/// A join link is structured data. Reading it is one field access; clicking it
/// is a screenshot, a grounding decision, a synthetic event and a verification
/// problem — and every one of those can fail. This type is rung one of the
/// ladder: prefer the data, and only fall to the screen when there is none.
///
/// Pure by design — no EventKit, no AppKit — so the matching rules are tested
/// without a calendar, a display, or a permission grant.
public enum MeetingLink {

    /// Hosts whose URLs are join links, most specific first. Order decides
    /// ties: an event carrying both a Teams link and a docs link joins Teams.
    ///
    /// Substring-matched against the host only, never the whole URL, so a
    /// page that merely *mentions* zoom.us in its path cannot impersonate one.
    static let hosts: [String] = [
        "teams.microsoft.com", "teams.live.com",
        "zoom.us", "zoomgov.com",
        "meet.google.com",
        "webex.com",
        "chime.aws",
        "whereby.com",
        "gotomeeting.com", "gotomeet.me",
        "bluejeans.com",
        "meet.jit.si",
        "discord.gg", "discord.com",
        "around.co",
        "riverside.fm",
        "skype.com",
    ]

    /// Every http(s) URL in a blob of text, in the order they appear.
    ///
    /// Calendar notes are HTML-ish and full of trailing punctuation — a link
    /// at the end of a sentence, a URL wrapped in angle brackets by a mail
    /// client, one closing an HTML attribute. Those characters are stripped
    /// from the tail, but never from the middle, because query strings
    /// legitimately contain almost everything.
    static func urls(in text: String) -> [String] {
        // Brackets open as well as close: notes routinely read
        // "(https://meet.google.com/a-b-c)", and treating ")" as trailing
        // punctuation while leaving "(" attached loses the link entirely,
        // because the token then does not start with a scheme.
        //
        // A comma separates too. "https://zoom.us/j/1,https://meet.google.com/x"
        // is one token otherwise, and it passes the host check on the first
        // URL while carrying the second along into the browser.
        let separators: Set<Character> = [
            "\"", "'", "<", ">", "(", ")", "[", "]", "{", "}", "|", "\\", ",",
        ]
        var found: [String] = []
        for token in decodingEntities(text)
            .split(whereSeparator: { $0.isWhitespace || separators.contains($0) }) {
            var s = String(token)
            guard s.lowercased().hasPrefix("https://")
                    || s.lowercased().hasPrefix("http://") else { continue }
            // Sentence punctuation only, and only from the tail: a query
            // string legitimately contains almost everything.
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            if s.count > "https://".count && s.count <= maxLength { found.append(s) }
        }
        return found
    }

    /// The handful of HTML entities that survive into a calendar's notes.
    ///
    /// Outlook invite bodies are HTML-derived, and a Teams `meetup-join` URL
    /// routinely carries `?context=…&amp;anon=true`. Left encoded, the link is
    /// returned looking perfectly valid and opens to an error — and a
    /// confidently wrong join link is worse than none, because the failure
    /// surfaces in the browser rather than as "I could not find it".
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&#x26;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: " ")
            .replacingOccurrences(of: "&lt;", with: " ")
            .replacingOccurrences(of: "&gt;", with: " ")
    }

    /// A join link goes into a prompt and may be opened. Cap it so a hostile
    /// or broken invite cannot push a 500 KB "URL" into the daily brief, which
    /// is re-sent on every turn.
    static let maxLength = 2048

    static func host(of urlString: String) -> String? {
        URL(string: urlString)?.host?.lowercased()
    }

    /// True when this URL points at a service people hold meetings on.
    public static func isJoinLink(_ urlString: String) -> Bool {
        guard isWellFormed(urlString), let host = host(of: urlString) else { return false }
        // A trailing root dot is the same host to DNS and a different string
        // to us: "zoom.us." must match "zoom.us".
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        return hosts.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }

    /// Reject the shapes where Foundation and a browser disagree about the host.
    ///
    /// Foundation parses `https://evil.com\@zoom.us/` as host `zoom.us` with
    /// `evil.com\` as userinfo. The WHATWG URL spec that Chrome and Safari
    /// implement treats a backslash in the authority as a slash, so the
    /// browser goes to **evil.com**. Anything with userinfo or a backslash is
    /// refused rather than reasoned about: no legitimate meeting link has
    /// either, and the cost of being wrong is opening an attacker's page from
    /// an invite anyone can send.
    static func isWellFormed(_ urlString: String) -> Bool {
        if urlString.count > maxLength { return false }
        if urlString.contains("\\") { return false }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil
        else { return false }
        return true
    }

    /// The join link for an event, or nil.
    ///
    /// `url` is checked first because that is the field Calendar itself uses
    /// to draw its Join button — if macOS can find a link there, so can we,
    /// and it needs no guessing. `location` comes next (Google Calendar puts
    /// the Meet link there), then `notes`, which is where Outlook buries a
    /// Teams link inside a wall of legal boilerplate.
    ///
    /// A recognised host always wins over an unrecognised one, wherever it
    /// was found — an Outlook invite whose `url` is a webmail permalink and
    /// whose notes hold the real Teams link must join Teams. When nothing is
    /// recognised, an `url` field is still returned as a last resort, because
    /// the organiser put it there on purpose; a bare URL loose in the notes
    /// is not, because notes are full of links to unrelated things.
    public static func find(url: String? = nil,
                            location: String? = nil,
                            notes: String? = nil) -> String? {
        var candidates: [String] = []
        if let url, !url.isEmpty { candidates.append(url) }
        for field in [location, notes] {
            guard let field, !field.isEmpty else { continue }
            candidates.append(contentsOf: urls(in: field))
        }

        // Recognised hosts first, ranked by the table's own order so a Teams
        // link beats a Discord one on an event that somehow carries both.
        // Rank once per candidate rather than on every comparison: `min(by:)`
        // would otherwise re-parse each URL O(n) times. `min` keeps the first
        // element on a tie, so field order (url, then location, then notes)
        // and document order within a field decide it — deterministically.
        let known = candidates.filter(isJoinLink).map { (rank($0), $0) }
        if let best = known.min(by: { $0.0 < $1.0 }) {
            return best.1
        }
        // Deliberate: an unrecognised URL on the event's own `url` field is
        // still offered, because the organiser put it there on purpose and a
        // company's internal meeting host will never be in `hosts`. It is
        // labelled `join:` for the agent, so it must at least be a real
        // http(s) URL with no host ambiguity — `isWellFormed`, not
        // `hasPrefix("http")`, which accepted `httpfoo://evil.com/x`.
        if let url, !url.isEmpty, isWellFormed(url) { return url }
        return nil
    }

    static func rank(_ urlString: String) -> Int {
        guard let host = host(of: urlString) else { return hosts.count }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        for (i, h) in hosts.enumerated() where bare == h || bare.hasSuffix("." + h) {
            return i
        }
        return hosts.count
    }
}
