import Foundation

/// What the dialog has been asked to show.
///
/// The request arrives on **stdin**, not on argv, and that is the point: argv
/// is world-readable through `ps`, and this process is handed the exact words
/// of a private message every time it runs. The format is deliberately not
/// JSON — `moe-home/tools/confirm.sh` is the caller, it is bash 3.2, and a
/// gate that needs python3 to build its own input is a gate with one more way
/// to fail closed on a working Mac. So: `key=value` records separated by NUL.
/// A value may contain anything at all, newlines and `=` included, because
/// only the first `=` is a separator and only NUL ends a record.
///
/// Unknown keys are ignored rather than refused. A newer confirm.sh talking to
/// an older dialog should lose a subtitle, not a send.
struct ConfirmRequest {
    /// What a person calls the thing this is going out on: "Gmail",
    /// "WhatsApp", "Telegram". May arrive as a raw tool name, in which case
    /// `Service` cleans it up rather than showing `mcp__moe__gmail_send` to
    /// a human.
    var channel = ""
    /// Every recipient, on one line. Never abbreviated here — what this shows
    /// and what the envelope gets have to be the same thing.
    var to = ""
    /// The message. Shown whole; the dialog scrolls.
    var body = ""
    /// The tool that asked, verbatim, for the quiet line at the bottom. The
    /// prettified channel is for reading; this is for believing.
    var tool = ""
    /// Icon key into `Resources/ServiceIcons` — derived from the channel when
    /// the caller does not know it.
    var service = ""
    /// The primary button. "Send" unless a caller has something truer to say
    /// ("Press Return", "Quit").
    var action = "Send"
    /// "send": a message leaves; Send / Cancel, never remembered.
    /// "act": a tool that changes things, or one nobody has vouched for;
    /// Do it / Always allow / Cancel.
    /// "session": a send in a browser or on the screen whose yes covers the
    /// rest of the conversation; Send / Allow everything this session /
    /// Cancel. Anything else is read as "send".
    var kind = "send"
    /// Code the caller wants shown UNDER the sentence, as code — the script a
    /// browser call is about to run. Until 2026-09-16 it arrived inside the
    /// message, four hundred characters squashed onto one line after the
    /// sentence a person was meant to read; the owner's words for it were
    /// "technical, very ugly, and very unclear". Shown, never editable, and
    /// never part of what an edit sends back.
    var detail = ""
    /// One line saying what is being asked and where — "Create an account on
    /// fazier.com?", "Type “me@x.com” into fazier.com and press “Forget
    /// Password”". When there is one the card leads with it, in place of the
    /// service's name, and the tool's arguments or code sit behind "Show
    /// details" (the owner, 2026-09-29: "why do they look so technical and
    /// unsimple? There is no idea what's going on").
    var headline = ""
    /// Whether the caller can put a rewritten message into what it sends.
    /// "no" from a caller that cannot — the hook, for a call whose message
    /// it found nowhere it can write back to — draws the message read-only.
    /// Anything else is "yes": every connector of Moe's own applies an edit.
    var edit = "yes"
    /// Who is waiting on the answer, as process ids (`ConfirmLifecycle.pids`),
    /// and the absolute time after which nobody is. When either says the
    /// wait is over, the card withdraws instead of hanging on for ever.
    var requester = ""
    var deadline = ""
    /// The Moe home `confirm.sh` runs from, where a withdrawn card leaves
    /// its sentence (`ConfirmLifecycle.inbox`).
    var home = ""
    /// Set when no person started the turn that asked (a scheduled job,
    /// background work) and the owner is at the Mac: the card says so, so it
    /// is not mistaken for part of what they are doing now. A label only.
    var origin = ""
    /// Who named the recipient (`ConfirmProvenance`), when the caller knows.
    /// `nil` says nothing, which is what an older caller sends.
    var provenance: ConfirmProvenance?
    /// Every word the primary button is allowed to say.
    static let actions = ["Send", "Press", "Quit", "Post", "Reply", "Type", "Do it", "Create account"]
    /// Something arrived that this format cannot represent. Not shown — asked
    /// the other way, which is what exit 2 means.
    var malformed = false

    /// Parses the NUL-separated records. Invalid UTF-8 is repaired rather
    /// than rejected: a message with one bad byte in it is still a message a
    /// person has to be shown before it goes out.
    static func parse(_ data: Data) -> ConfirmRequest {
        var request = ConfirmRequest()
        var namedAction = false
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: record, as: UTF8.self)
            // A record with no `=` is not a record. Skipping it was forgiving
            // in the wrong direction: a NUL inside a value splits that value
            // in two, and the tail re-enters the parser as records — which is
            // how a body could end up replacing the recipient. Neither caller
            // can produce a NUL today; this is the choke point, so it refuses.
            guard let split = text.firstIndex(of: "=") else {
                request.malformed = true
                continue
            }
            let key = String(text[text.startIndex..<split])
            let value = String(text[text.index(after: split)...])
            switch key {
            case "channel": request.channel = value
            case "to":      request.to = value
            case "body":    request.body = value
            case "tool":    request.tool = value
            case "service": request.service = value
            // A closed set. `action=Cancel` would have labelled the button
            // that SENDS "Cancel", beside a Cancel button that also cancels.
            case "action":  request.action = Self.actions.contains(value) ? value : "Send"
                            namedAction = true
            case "kind":    request.kind = value == "act" ? "act" : value == "session" ? "session" : "send"
            case "edit":    request.edit = value == "no" ? "no" : "yes"
            case "detail":  request.detail = value
            case "headline": request.headline = value
            case "requester": request.requester = value
            case "deadline":  request.deadline = value
            case "home":      request.home = value
            case "origin":    request.origin = value
            case "provenance": request.provenance = ConfirmProvenance(json: value)
            default:        break
            }
        }
        if request.kind == "act" && !namedAction { request.action = "Do it" }
        // A session dialog is a send when it is about a message going out —
        // a browser send, a Return on the screen — and "Do it" for a
        // payment, a deletion, a password or a consent screen.
        if request.kind == "session" && !namedAction {
            let c = request.channel.lowercased()
            request.action = (c.hasPrefix("browser send") || c.hasPrefix("computer_use")) ? "Send" : "Do it"
        }
        // A new account with a password Moe makes (the hook's "browser
        // account", ticket #17) is asked as a plain send — every time, never
        // remembered — but nothing is sent: the button says what it does.
        if request.isNewAccount && !namedAction {
            request.action = "Create account"
        }
        return request
    }

    /// A new account with a password Moe makes (the hook's "browser
    /// account", ticket #17): asked as a plain send — every time, never
    /// remembered — but nothing is sent, so the buttons say what they do.
    var isNewAccount: Bool {
        kind == "send" && channel.lowercased().hasPrefix("browser account")
    }

    /// The button that says no. "Not now" where the question is an offer
    /// (make an account) rather than a message to stop.
    var cancelLabel: String { isNewAccount ? "Not now" : "Cancel" }

    /// Whether anything is being SENT, as opposed to done: what the line
    /// above the heading says has not happened yet.
    var sends: Bool {
        if isNewAccount { return false }
        if kind == "send" { return true }
        if kind == "session" {
            let c = channel.lowercased()
            return c.hasPrefix("browser send") || c.hasPrefix("computer_use")
        }
        return false
    }

    /// The three-argument shape `confirm.sh` itself takes, so the dialog can
    /// be looked at by hand:
    ///
    ///     moe-confirm "Gmail" "dad@example.com" "Running late"
    ///
    /// Debug only. Anything real should come in on stdin — see above.
    static func parse(argv: [String]) -> ConfirmRequest {
        var request = ConfirmRequest()
        if argv.count > 0 { request.channel = argv[0] }
        if argv.count > 1 { request.to = argv[1] }
        if argv.count > 2 { request.body = argv[2] }
        return request
    }

    /// The recipient, without the platform prefix the heading already says.
    ///
    /// One Hermes tool addresses every platform through a single string —
    /// `teams:#engineering`, `slack:#general`, `signal:+1555…` — so the
    /// service and the recipient arrive glued together. Splitting them puts
    /// the mark and the name in the heading and leaves the To line saying who
    /// this is actually going to. Nothing is hidden: the half removed here is
    /// the half printed in 24pt above it.
    var displayedTo: String {
        // `legibleLine`, not `legible`: a newline is not in the steering set
        // (a message may have them) but the To field is one line, and
        // `telegram.py` builds its recipient from the contact's own
        // first_name/last_name off the wire — text the connector never runs
        // through its own BAD_TEXT_RE, because it validates the caller's
        // argument and then passes a different string.
        let shown = Self.legibleLine(to)
        let prefix = service + ":"
        // Only when the heading really is that service. A hint the dialog did
        // not believe must not still take a prefix off the recipient, or the
        // To line would lose the one word that showed the disagreement.
        let resolved = Service.identified(channel: channel, tool: tool, hint: service).key
        guard !service.isEmpty, resolved == service.lowercased(),
              shown.lowercased().hasPrefix(prefix.lowercased()) else { return shown }
        let rest = shown.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? shown : String(rest)
    }

    /// Characters that make a screen show one thing while the bytes say
    /// another: the bidi overrides and isolates, the line/paragraph
    /// separators, and the control characters.
    ///
    /// `gmail.py`, `telegram.py` and `whatsapp.sh` all refuse these before
    /// they will send, with the reason written out: "a gate whose display can
    /// be steered is not a gate". They are right, and until now this dialog —
    /// the one screen every caller goes through — did not apply the same rule
    /// to text arriving from the Hermes hook, which is arbitrary tool
    /// arguments. Measured with the real font: `U+202E` + "4444555551+"
    /// renders as "+1555554444", so a person could approve a number and a
    /// different one could be dialled.
    ///
    /// Shown rather than refused. Refusing sends the caller to the AppleScript
    /// dialog, which reorders text exactly the same way; naming the character
    /// where it sits takes the trick away and still lets a person decide.
    static let steering: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.insert(charactersIn: "\u{2028}"..."\u{2029}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert("\u{200E}")
        set.insert("\u{200F}")
        // Characters that take up room, or none, and draw nothing either way.
        // 850 braille blanks between "Dad" and the real number pushed the
        // number past the bottom of a 340pt panel with no visual cue; Hangul
        // filler does the same with no width at all, so
        // `dad@example.com␣␣␣attacker@evil.com` drew as one unbroken address.
        // The hook's `\s+` normaliser matches none of them.
        for scalar in ["\u{00AD}", "\u{180E}", "\u{200B}", "\u{200C}", "\u{200D}",
                       "\u{2060}", "\u{2800}", "\u{3164}", "\u{FEFF}", "\u{FFA0}"] {
            set.insert(charactersIn: scalar)
        }
        set.remove("\n")
        set.remove("\t")
        return set
    }()

    /// Letters that flip the reading order without any override character.
    /// One Hebrew word in front of an address moves it to the far right of
    /// the line: the bytes and the picture disagree, and nothing says so.
    /// Not rewritten — a person writing Hebrew is not attacking anyone — but
    /// it is worth saying that the order on screen is not the order sent.
    static let rightToLeft: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\u{0590}"..."\u{05FF}")   // Hebrew
        set.insert(charactersIn: "\u{0600}"..."\u{06FF}")   // Arabic
        set.insert(charactersIn: "\u{0700}"..."\u{074F}")   // Syriac
        set.insert(charactersIn: "\u{FB1D}"..."\u{FDFF}")   // presentation forms
        set.insert(charactersIn: "\u{FE70}"..."\u{FEFC}")
        return set
    }()

    /// `text` with every steering character replaced by its own name.
    /// For the fields that are drawn on one line: a break is named rather
    /// than obeyed, so a heading cannot grow a second line of its own.
    static func legibleLine(_ text: String) -> String {
        legible(text).text
            .replacingOccurrences(of: "\n", with: "⟨U+000A⟩")
            .replacingOccurrences(of: "\r", with: "⟨U+000D⟩")
    }

    static func legible(_ text: String) -> (text: String, steered: Bool) {
        guard text.rangeOfCharacter(from: steering) != nil else { return (text, false) }
        var out = ""
        for scalar in text.unicodeScalars {
            if steering.contains(scalar) {
                out += String(format: "⟨U+%04X⟩", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return (out, true)
    }

    /// Past this SwiftUI cannot lay the text out in any time worth waiting
    /// for: a 216 KB body left the dialog with no window at all after forty
    /// seconds at 100% CPU — and `confirm.sh` waits on the pipe, so the gate
    /// never appeared at all. What is drawn is cut here, with the number of
    /// characters it is not showing said out loud, exactly as the AppleScript
    /// dialog has always had to do.
    static let drawableBody = 20_000

    /// The message as it will be drawn: legible, and short enough to draw.
    var displayedBody: String {
        let full = Self.legible(fields.body).text
        guard full.count > Self.drawableBody else { return full }
        return String(full.prefix(Self.drawableBody)) + "…\n\n⚠️ "
            + "\(full.count - Self.drawableBody) more characters follow that are "
            + "NOT shown here. They will be sent. Cancel if you have not read them."
    }

    /// Whether the message may be rewritten here before it goes.
    ///
    /// Only a send — an act has no message to rewrite — and only when the
    /// caller can put the edit into what it sends. And only when what is
    /// drawn IS the message: a body whose steering characters were named, or
    /// whose tail was cut off to be drawable, is being shown rather than
    /// offered, and an edit made through that picture would carry the
    /// picture's marks into the message. Those stay read-only.
    var editable: Bool {
        guard kind == "send", edit != "no" else { return false }
        let message = fields.body
        return !Self.legible(message).steered && message.count <= Self.drawableBody
    }

    /// The subject may be rewritten when the message may, and it was shown
    /// whole: `fields` cuts a header value past `maxHeaderValue`, and an
    /// edit made to the cut copy would send the cut copy.
    var subjectEditable: Bool {
        guard editable, let subject = fields.headers.first(where: { $0.0.caseInsensitiveCompare("Subject") == .orderedSame })
        else { return false }
        return subject.1.count <= Self.maxHeaderValue && !Self.legible(subject.1).steered
    }

    /// True when anything on screen had to be rewritten to be readable.
    var steered: Bool {
        for text in [to, body, channel, service, tool, action, headline] {
            if Self.legible(text).steered { return true }
            if text.rangeOfCharacter(from: Self.rightToLeft) != nil { return true }
        }
        // A newline is ordinary in a message and impossible in a heading, a
        // recipient or a tool id. `service = "Gmail\nTo: dad@example.com"`
        // drew a two-line heading at 24pt claiming a recipient that was not
        // the one being sent to.
        for line in [to, channel, service, tool, action, headline] where line.contains("\n") {
            return true
        }
        return false
    }

    /// A recipient written in characters that only LOOK like the ones a
    /// person reads. `dad@exаmple.com` with a Cyrillic а differs from the
    /// real address by about a thousand sub-pixels: rendered side by side at
    /// the real font, I could not tell them apart, and neither could anyone.
    /// Not refused — plenty of real addresses are not ASCII — but named.
    var confusableRecipient: String? {
        let suspicious = displayedTo.unicodeScalars.filter { $0.value > 127 }
        guard !suspicious.isEmpty else { return nil }
        let names = Set(suspicious.map { scalar -> String in
            "\(String(scalar)) (U+\(String(format: "%04X", scalar.value)))"
        }).sorted().prefix(6).joined(separator: ", ")
        return "This recipient is not plain ASCII: \(names). Letters like these can "
             + "look identical to ordinary ones."
    }

    /// The header lines Moe's own connectors put on the front of a message
    /// body — `gmail.py` sends `From: …\nSubject: …\n\n…` — pulled out so they
    /// can be shown as fields instead of as the first two lines of the mail.
    ///
    /// Nothing is hidden by this: every line either becomes a labelled field
    /// or stays in the body. It only runs on a *leading, unbroken* run of
    /// known header lines ending in a blank line, which is exactly the shape
    /// the connectors write and nothing like the shape prose has.
    /// Deliberately no `To`, `Cc` or `Bcc`. Those are claims about who is
    /// receiving this, and the dialog already draws that line from the
    /// recipient the caller passed. Read out of the body they were drawn in
    /// the same style, so a message beginning "To: dad@example.com" produced
    /// a second TO row that nothing had checked — two recipients on screen,
    /// one of them written by whoever wrote the message.
    static let headerNames = ["From", "Subject", "Reply-To", "In-Reply-To"]

    /// How many header lines are worth showing, and how long each may be.
    /// A body of 50,000 `From:` lines produced no window at all — offscreen
    /// layout of that many rows never returned, and `confirm.sh` waits on the
    /// pipe with no timeout, so the send hung for ever. A single 300,000
    /// character header value gave a 98,367pt window. The connectors' own
    /// header block is four lines and a few hundred characters.
    static let maxHeaders = 8
    static let maxHeaderValue = 300

    /// Only mail has a header block. A Slack or WhatsApp body beginning
    /// "From: ceo@company.com" was drawing an authoritative FROM row in the
    /// same style as the real fields, and nothing had checked it — the
    /// connectors that legitimately put From:/Subject: on the front of a body
    /// are the mail ones, and only those.
    private var carriesMailHeaders: Bool {
        let where_ = (channel + " " + tool + " " + service).lowercased()
        return ["gmail", "mail", "outlook", "smtp", "imap"].contains { where_.contains($0) }
    }

    var fields: (headers: [(String, String)], body: String) {
        guard carriesMailHeaders else { return ([], body) }
        var headers: [(String, String)] = []
        var lines = body.components(separatedBy: "\n")
        var taken = 0
        for line in lines.prefix(Self.maxHeaders + 1) {
            guard headers.count < Self.maxHeaders else { break }
            guard let colon = line.firstIndex(of: ":") else { break }
            let name = String(line[line.startIndex..<colon])
            guard Self.headerNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { break }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value.count > Self.maxHeaderValue
                            ? String(value.prefix(Self.maxHeaderValue)) + "…"
                            : value))
            taken += 1
        }
        // A run of headers not followed by a blank line is prose that happens
        // to start "Subject: …". Leave it alone.
        guard taken > 0, lines.count > taken, lines[taken].trimmingCharacters(in: .whitespaces).isEmpty
        else { return ([], body) }
        lines.removeFirst(taken + 1)
        return (headers, lines.joined(separator: "\n"))
    }
}

/// Which service this is going out on, for the mark and the name.
///
/// The caller may know ("Gmail", from a connector) or may not (the Hermes hook
/// sees `mcp__moe__gmail_send` and nothing else). Either way a person should
/// read the name of a thing they have heard of, so the tool id is matched
/// against the services Moe knows and, failing that, tidied into words.
enum Service {
    /// Longest keys first, so `drive-docs` wins over `drive`,
    /// `whatsapp_cloud` over `whatsapp`, and `google_chat` is never read as
    /// Gmail.
    ///
    /// Key and label only. The mark is looked up by the key itself, on disk,
    /// by `ServiceIcons.art` — which already falls back to an SF Symbol and
    /// then to a monogram. A hand-written icon column beside this was a
    /// second catalogue mirroring `ls Resources/ServiceIcons`, kept honest by
    /// a test that existed only because of the duplication, and it was wrong
    /// in both directions: five platforms the hook can name had no row here
    /// at all, and `buzz` had bundled art that could never be drawn.
    private static let known: [(key: String, label: String)] = [
        ("whatsapp_cloud", "WhatsApp"),
        ("google_chat", "Google Chat"),
        ("googlechat", "Google Chat"),
        // The broker's toolkit slugs. The hook now hands the dialog a slug
        // like `googledrive` when a tool is one of Composio's, and without a
        // row here `identified` tidied it into the heading "Googledrive" and
        // asked for a mark by a name no row owned — so the dialog drew a
        // monogram while Resources/ServiceIcons/googledrive.svg sat unused.
        // A review caught that the commit claiming "draws Google Drive's own
        // mark" was measurably wrong; these are the rows that make it true.
        // Longest first, as the comment above requires: `googlecalendar`
        // must be tried before `googledocs` before `gcal`.
        ("googlecalendar", "Google Calendar"),
        ("googleslides", "Google Slides"),
        ("googlephotos", "Google Photos"),
        ("googlesheets", "Google Sheets"),
        ("googletasks", "Google Tasks"),
        ("googledrive", "Google Drive"),
        ("googledocs", "Google Docs"),
        ("googlemeet", "Google Meet"),
        ("bluebubbles", "iMessage"),
        ("mattermost", "Mattermost"),
        ("sharepoint", "SharePoint"),
        ("drive-docs", "Google Docs"),
        ("homeassistant", "Home Assistant"),
        // Platforms Hermes can address that had no row here at all, so the
        // dialog tidied their tool name instead of naming them. `buzz` even
        // had bundled art that could never be drawn.
        ("dingtalk", "DingTalk"),
        ("yuanbao", "Yuanbao"),
        ("simplex", "SimpleX"),
        ("photon", "Photon"),
        ("wecom", "WeCom"),
        ("buzz", "Buzz"),
        ("raft", "Raft"),
        ("a2a", "another agent"),
        ("whats_app", "WhatsApp"),
        ("whatsapp", "WhatsApp"),
        ("instagram", "Instagram"),
        ("messenger", "Messenger"),
        ("microsoft", "Microsoft"),
        ("mastodon", "Mastodon"),
        ("imessage", "iMessage"),
        ("telegram", "Telegram"),
        ("linkedin", "LinkedIn"),
        ("onedrive", "OneDrive"),
        ("intercom", "Intercom"),
        ("zendesk", "Zendesk"),
        ("messages", "Messages"),
        ("mailgun", "Mailgun"),
        ("sendgrid", "SendGrid"),
        ("bluesky", "Bluesky"),
        // The browser itself: what a browser session on a site with no mark
        // of its own is headed with, drawn with Chrome's.
        ("chrome", "Chrome"),
        ("discord", "Discord"),
        ("outlook", "Outlook"),
        ("hubspot", "HubSpot"),
        ("twilio", "Twilio"),
        ("signal", "Signal"),
        ("matrix", "Matrix"),
        ("feishu", "Feishu"),
        ("wechat", "WeChat"),
        ("gmail", "Gmail"),
        ("teams", "Teams"),
        ("slack", "Slack"),
        ("zulip", "Zulip"),
        ("notion", "Notion"),
        ("linear", "Linear"),
        ("github", "GitHub"),
        ("gitlab", "GitLab"),
        ("todoist", "Todoist"),
        ("trello", "Trello"),
        ("zoom", "Zoom"),
        ("ntfy", "ntfy"),
        ("line", "LINE"),
        ("viber", "Viber"),
        ("irc", "IRC"),
        ("jira", "Jira"),
        ("tweet", "X"),
        ("twitter", "X"),
        ("email", "Email"),
        ("smtp", "Email"),
        ("mail", "Email"),
        ("sms", "SMS"),
    ]

    /// The six keys whose file is not named after them.
    private static let iconAlias = [
        "googlechat": "google_chat", "whats_app": "whatsapp",
        "tweet": "x", "twitter": "x", "smtp": "email", "mail": "email",
    ]

    private static func icon(for key: String) -> String {
        iconAlias[key] ?? key
    }

    /// The name to put in the heading, and the icon key to draw beside it.
    static func identify(channel: String, tool: String, hint: String) -> (label: String, icon: String) {
        identified(channel: channel, tool: tool, hint: hint).0
    }

    /// Also reports WHICH key was matched, so the caller can tell whether the
    /// hint was believed — the recipient keeps its prefix when it was not.
    static func identified(channel: String, tool: String,
                           hint: String) -> ((label: String, icon: String), key: String) {
        let haystack = (channel + " " + tool).lowercased()
        // The tool id first, always. The hint is read off the recipient
        // string, which the model wrote: `to: "gmail:#general"` on
        // mcp__slack__chat_postMessage headed the dialog "Gmail", with
        // Gmail's own mark, over a message going to Slack. When the two
        // disagree, the one chosen by the tool's author wins.
        for segment in Self.serverSegments(of: tool) {
            if let match = known.first(where: { $0.key == segment }) {
                return ((match.label, icon(for: match.key)), match.key)
            }
        }
        // A third party's server that is not in the table names itself: the
        // Pulse server's `search_messages` is a warehouse query, not Apple
        // Messages, and a bare Hermes tool nobody knows is "Hermes", not
        // "Tool". Only Moe's own surfaces fall through to the name scan.
        let own: Set<String> = ["moe", "hermes-tools", "hermes_tools"]
        if let inner = Self.serverSegments(of: tool).last, !own.contains(inner) {
            if let match = known.first(where: { $0.key == hint.lowercased() }) {
                return ((match.label, icon(for: match.key)), match.key)
            }
            return ((tidy(hint.isEmpty ? inner : hint), ""), "")
        }
        // Then the tool id itself. Every Moe and Hermes tool has server `moe`
        // or `hermes-tools`, so the platform lives in the NAME — which meant
        // the hint, read off a recipient string the model wrote, still won
        // for `mcp__moe__gmail_send` with `service=slack`: Slack's heading,
        // Slack's mark, over an email. Anything the tool's own name says
        // outranks anything the recipient claims.
        if let match = known.first(where: { haystack.contains($0.key) }) {
            return ((match.label, icon(for: match.key)), match.key)
        }
        if !hint.isEmpty {
            if let match = known.first(where: { $0.key == hint.lowercased() }) {
                return ((match.label, icon(for: match.key)), match.key)
            }
            return ((tidy(hint), ""), "")
        }
        return ((tidy(channel), ""), "")
    }

    /// `mcp__hermes-tools__mcp__moe__gmail_send` → ["hermes-tools", "moe"].
    static func serverSegments(of tool: String) -> [String] {
        var segments: [String] = []
        var rest = Substring(tool.lowercased())
        while rest.hasPrefix("mcp__") {
            rest = rest.dropFirst(5)
            guard let end = rest.range(of: "__") else { break }
            segments.append(String(rest[rest.startIndex..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return segments
    }

    /// `mcp__moe__gmail_send` → `Gmail send`. The last resort, and it still
    /// beats showing a person a tool id and hoping.
    static func tidy(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "__", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        text = text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "message" }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
