import Foundation

// The pure pieces of the meeting *experience* (MEETING-MODE.md, Phase A2):
// what the island answers itself, what goes to the brain every minute, and
// the small state machines around "you were away" and "your name came up".
// Nothing here touches audio, the network or files; all of it is unit-tested.

// MARK: - The transcript tail

public enum TranscriptTail {
    /// How much of the live transcript rides along with a question asked
    /// mid-meeting, and how much the panel shows.
    public static let lines = 40

    /// The newest `max` segments, oldest first.
    public static func tail(_ segments: [Segment], max: Int = lines) -> [Segment] {
        Array(segments.suffix(Swift.max(0, max)))
    }

    /// The tail as `[mm:ss] who: text` lines, for the brain.
    public static func context(_ segments: [Segment], max: Int = lines) -> String {
        Timeline.format(tail(segments, max: max))
    }
}

// MARK: - The line under the transcript

/// "331 lines · 4 voices", and the one case worth wording differently.
///
/// It used to read "331 lines", which is a fact about the panel rather than
/// about the meeting: someone reading along already knows roughly how much
/// has been said. How many voices Moe has managed to tell apart is the
/// number they cannot get any other way — and on 2026-09-08 it is the
/// number that would have shown a dead call-audio stream inside the first
/// minute, with a six-person call transcribing as **one** voice, all of it
/// filed under the owner's name.
public enum TranscriptFooter {

    /// How many distinct people the timeline believes it has heard.
    ///
    /// `you` is one; each numbered `them` is one; an unnumbered `them` is
    /// one between them all, because until the end-of-meeting diarization
    /// runs that is genuinely all that is known. Counting it as many would
    /// be inventing a number; counting it as none would hide the far end
    /// entirely for the whole of a live call, which is the opposite of what
    /// this is for.
    public static func voices(_ segments: [Segment]) -> Int {
        var numbered = Set<Int>()
        var anonymousThem = false
        var you = false
        for seg in segments {
            switch seg.speaker {
            case .you: you = true
            case .them(let n?): numbered.insert(n)
            case .them(nil): anonymousThem = true
            }
        }
        return (you ? 1 : 0) + numbered.count + (anonymousThem ? 1 : 0)
    }

    public static func line(_ segments: [Segment]) -> String {
        let n = segments.count
        let lines = "\(n) line\(n == 1 ? "" : "s")"
        guard n > 0 else { return lines }
        let v = voices(segments)
        // The case worth naming. One voice, and it is the microphone's, is
        // exactly what a dead call-audio stream looks like from here.
        if v == 1, segments.allSatisfy(\.speaker.isYou) { return "\(lines) · only your voice" }
        return "\(lines) · \(v) voice\(v == 1 ? "" : "s")"
    }
}

// MARK: - "What did they just say?"

/// Answered locally, at once: the last thing the other side said, or —
/// when nobody on the far end has spoken yet — everything from the last
/// `window` seconds, whoever said it.
public enum TranscriptRecall {
    public static let window: Double = 20

    public static func answer(_ segments: [Segment], now: Double) -> String {
        if let last = segments.last(where: { !$0.speaker.isYou }) {
            return "They said (\(Timeline.clock(last.start))): \u{201C}\(last.text)\u{201D}"
        }
        let recent = segments.filter { $0.end >= now - window }
        guard !recent.isEmpty else {
            return segments.isEmpty ? "Nothing has been transcribed yet." : "Nothing from them yet — only you have spoken so far."
        }
        return "Last \(Int(window)) s:\n" + Timeline.format(recent)
    }
}

// MARK: - Talk about the meeting is not work

/// The one sentence both prompts need, in one place.
///
/// The 14:00 meeting on 2026-09-08 produced, among its action items,
/// `you — "Restart the meeting recording"`. Nobody had agreed to any such
/// thing: someone on the call had asked whether it was being recorded and
/// whether transcription was on. Setting up the recording is the scaffolding
/// around a meeting, not a commitment made in one, and it turns up in almost
/// every call Moe is in — because Moe being there is what prompts it.
public enum MeetingChatter {
    public static let rule =
        "Ignore anything about the meeting's own machinery — recording, transcribing, "
        + "muting, cameras, screen sharing, links, who can hear whom, or asking Alfie "
        + "itself for something. That is scaffolding around the meeting, never work "
        + "agreed in it."
}

// MARK: - Action items, every minute

/// The tiny prompt that goes to Hermes every two minutes with the lines
/// heard since the last one, and what comes back.
public enum ActionItemScan {
    /// Two minutes, not one: every call is a turn on the person's plan or
    /// key, and a count on the island arriving a minute later costs nothing —
    /// the summary at the end confirms the items either way. Decided by the
    /// owner, 2026-09-15, after a meeting's 61 scans were measured.
    public static let interval: Double = 120

    public static let system = """
    You watch a meeting transcript as it grows and pick out action items — \
    concrete things someone committed to do. Lines are "[mm:ss] who: text"; \
    "you" is the person whose notes these are, "them" the others. Reply with \
    ONE JSON object and nothing else: {"actions":[{"who":"…","what":"…","when":"…"}]} \
    for what was agreed in THESE lines, or {} when there is nothing new. Be \
    strict: a task must be stated, not implied. \
    \(MeetingChatter.rule) \
    Never call a tool.
    """

    public static func user(newLines: String) -> String {
        "<new-lines>\n\(newLines)\n</new-lines>"
    }

    /// `{"actions":[…]}` → the items; `{}` or anything unreadable → none.
    /// Items may be strings or {who, what, when} objects, like the summary's.
    public static func parse(_ reply: String) -> [MeetingNotes.ActionItem] {
        guard let obj = MeetingNotes.jsonObject(in: reply) else { return [] }
        let list = (obj["actions"] as? [Any]) ?? (obj["action_items"] as? [Any]) ?? []
        return list.compactMap { item in
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : MeetingNotes.ActionItem(who: "", what: t, when: "")
            }
            guard let d = item as? [String: Any] else { return nil }
            let what = ((d["what"] as? String) ?? (d["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty else { return nil }
            return MeetingNotes.ActionItem(who: ((d["who"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                           what: what,
                                           when: ((d["when"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Words the filler list drops before two tasks are compared. Wider
    /// than it looks it needs to be on purpose: the live scan and the
    /// full-transcript pass phrase the same commitment differently —
    /// "create a new Telegram bot" against "create a new bot on Telegram" —
    /// and every word of that difference is filler.
    static let filler: Set<String> = [
        "the", "a", "an", "to", "will", "and", "or", "of", "in", "into", "on",
        "for", "it", "its", "is", "are", "be", "with", "that", "this", "at",
        "by", "from", "s", "do", "we", "i", "our", "up", "out", "also", "some", "any",
    ]

    /// The words that carry the task: lowercased, punctuation and filler
    /// gone. "Send the notes." and "send notes" come out the same set.
    public static func words(_ item: MeetingNotes.ActionItem) -> Set<String> {
        let letters = item.what.lowercased().unicodeScalars.map { u -> Character in
            CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) ? Character(u) : " "
        }
        return Set(String(letters).split(separator: " ").map(String.init).filter { !filler.contains($0) })
    }

    /// "you" is the note-taker and is never a speaker number, so the same
    /// task owned by "you" and by somebody else is two commitments rather
    /// than one repeated. Any other pair of names may well be one person
    /// under two labels — "Dan" and "them (speaker 2)" before the speaker
    /// was named — so it must not block a match.
    static func ownersAgree(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !x.isEmpty, !y.isEmpty else { return true }
        return (x == "you") == (y == "you")
    }

    /// One commitment said twice, in two different sets of words.
    ///
    /// Identical content words are the easy case. Beyond that the bar is
    /// deliberately high — at least three words in common, and those words
    /// more than half of the shorter task — because collapsing two real
    /// commitments into one loses work silently, while leaving a duplicate
    /// is merely untidy. "Send the deck" and "send the notes" share one
    /// word and stay apart; "get familiar with the aid/aid-venza workspace
    /// setup" and "get familiar with the aidvenza workspace setup" share
    /// five of six and become one.
    /// `requireSameOwner` is the `ownersAgree` bar above, and it is only
    /// worth paying when both items come from the pass that read the whole
    /// transcript. See `merge`.
    static func sameTask(_ a: MeetingNotes.ActionItem, _ b: MeetingNotes.ActionItem,
                         requireSameOwner: Bool = true) -> Bool {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        if requireSameOwner, !ownersAgree(a.who, b.who) { return false }
        if wa == wb { return true }
        let shared = wa.intersection(wb).count
        guard shared >= 3 else { return false }
        return Double(shared) / Double(min(wa.count, wb.count)) >= 0.5
    }

    /// `existing` plus whatever in `new` says something `existing` does not.
    /// Order kept, and `existing`'s wording wins — it comes from the pass
    /// that read the whole transcript, where the live scan saw one minute
    /// at a time. A repeat within either list counts once.
    ///
    /// # Whose name has to match
    ///
    /// Between two items the full read produced, `ownersAgree` stands: if
    /// that pass, having read everything, put one task on Ryan and one on
    /// the note-taker, they are two commitments and collapsing them loses
    /// somebody's work.
    ///
    /// A live-scan item is not that. It was written from sixty seconds of
    /// transcript whose speaker labels are provisional, and the 14:00
    /// meeting on 2026-09-08 shows what the strict rule costs there: 33
    /// action items where nine were distinct, in pairs like
    ///
    ///   Ryan  — "Check what level of 3CX access ISTA currently has"
    ///   you   — "Check with someone what level of 3CX access they have"
    ///
    /// — the same sentence, heard twice, and kept twice because the owners
    /// disagreed. (The mislabelling had its own cause, now fixed: the mic
    /// was recording the whole room while the call-audio stream was dead,
    /// so half the meeting was attributed to the note-taker. This is what
    /// stops the same thing happening for smaller reasons.)
    ///
    /// So a live-scan item is dropped when the full read already covers the
    /// task, whoever it named. That is not losing a commitment: it is
    /// preferring the reading that had the whole transcript to the one that
    /// had a minute of it.
    public static func merge(_ existing: [MeetingNotes.ActionItem], _ new: [MeetingNotes.ActionItem]) -> [MeetingNotes.ActionItem] {
        var out: [(item: MeetingNotes.ActionItem, fullRead: Bool)] = []
        let all = existing.map { ($0, true) } + new.map { ($0, false) }
        for (item, fullRead) in all {
            guard !words(item).isEmpty else { continue }
            let duplicate = out.contains { kept in
                sameTask(kept.item, item, requireSameOwner: fullRead && kept.fullRead)
            }
            guard !duplicate else { continue }
            out.append((item, fullRead))
        }
        return out.map(\.item)
    }
}

// MARK: - Catch me up

/// Away and back: the screen locked, the Mac slept, or no input for
/// `threshold` seconds. When the user is back the span they missed is
/// what the recap covers. Times are meeting seconds.
public struct CatchUp: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var seconds: Double { max(0, end - start) }
    }

    public var threshold: Double
    /// Set while the user is away; when it began, in meeting seconds.
    public private(set) var awaySince: Double?
    /// Locked / asleep: away regardless of the idle clock.
    public private(set) var locked = false

    public init(threshold: Double = 180) { self.threshold = threshold }

    public var isAway: Bool { awaySince != nil }

    /// The screen locked or the Mac is going to sleep.
    public mutating func lock(at t: Double) {
        locked = true
        if awaySince == nil { awaySince = t }
    }

    /// Unlocked / awake. The user is only "back" once input resumes, so
    /// this clears the lock and lets `observe` finish the span.
    public mutating func unlock() { locked = false }

    /// Feed the idle clock (seconds since the last input). Returns the span
    /// the user missed the moment they are back, else nil.
    public mutating func observe(idleSeconds: Double, at t: Double) -> Span? {
        if locked { return nil }
        if let since = awaySince {
            // Back: input in the last couple of seconds.
            guard idleSeconds < 2 else { return nil }
            awaySince = nil
            let span = Span(start: since, end: t)
            // A span too short to have missed anything is not worth a recap.
            return span.seconds >= threshold ? span : nil
        }
        if idleSeconds >= threshold {
            awaySince = max(0, t - idleSeconds)
        }
        return nil
    }

    /// What was said while away — the lines the recap is made from.
    public static func missed(_ segments: [Segment], in span: Span) -> [Segment] {
        segments.filter { $0.end > span.start && $0.start < span.end }
    }

    public static let system = """
    You recap part of a meeting for someone who stepped away. Lines are \
    "[mm:ss] who: text"; "you" is the person you are writing for, "them" the \
    others. Reply with exactly two sentences of plain text: what was \
    discussed while they were away and anything that needs them. No preamble, \
    no bullet points, no tool calls. If nothing of substance was said, say so \
    in one sentence.
    """

    public static func user(missed: [Segment], span: Span) -> String {
        "Away from \(Timeline.clock(span.start)) to \(Timeline.clock(span.end)).\n\n<missed>\n\(Timeline.format(missed))\n</missed>"
    }
}

// MARK: - Name mentions

/// The user's first name heard on the far side. Word boundaries, so "Dan"
/// is not in "Danish" or "Jordan"; a possessive ("Dan's") counts.
public enum NameMention {
    public static func matches(name: String, in text: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.count >= 2 else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: n) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The sentence of `text` the name is in, for the panel.
    public static func sentence(name: String, in text: String) -> String {
        let parts = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.first { matches(name: name, in: $0) } ?? text
    }

    /// The `them` segments among `segments[from...]` that name the user.
    public static func mentions(name: String, in segments: [Segment], from index: Int) -> [Segment] {
        guard !name.isEmpty, index < segments.count else { return [] }
        return segments[max(0, index)...].filter { !$0.speaker.isYou && matches(name: name, in: $0.text) }
    }
}

// MARK: - New lines since last time

/// Which lines of the live transcript have not yet gone to the brain: the
/// transcriber hands back the whole timeline each time, so the count of
/// lines already sent is the cursor. A rewrite of earlier lines (diarization
/// at the end) restarts from the front, which is harmless — it only
/// happens once and the summary dedupes.
public struct LiveCursor: Equatable, Sendable {
    public private(set) var sent = 0
    public init() {}

    public mutating func take(_ segments: [Segment]) -> [Segment] {
        if segments.count < sent { sent = 0 }
        let fresh = Array(segments[sent...])
        sent = segments.count
        return fresh
    }
}

// MARK: - The ring

// The red ring around the notch used to breathe with the room's level
// (`RingLevel`, a dBFS → 0…1 mapping plus a smoothing step). It is gone.
// The ring is a consent indicator: while a meeting is recorded it is
// steady red, and while it is off the record it is dim. A ring that
// pulses with the room reads as an animation to watch rather than a fact
// about what is being recorded — "it should just be red when it's
// recording". The levels themselves are still measured; they go to the
// log every 15 s (`LevelLog`) and to `ChannelHealth`, which is where a
// number about the microphone is actually useful.

// MARK: - Notes to Telegram, to yourself

/// Where the notes go after a meeting: the user's own Telegram, through
/// Hermes's `send_message` tool. The target is the first id in
/// `TELEGRAM_ALLOWED_USERS` — the people Hermes already answers to — and
/// only when a bot token is there at all. Read from Hermes's `.env`; never
/// written.
public enum TelegramSelf {
    /// `telegram:<id>` from the text of a `.env`, or nil when Telegram is
    /// not configured. Quotes and `export` are tolerated.
    public static func target(envText: String) -> String? {
        var token = ""
        var users: [String] = []
        for raw in envText.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "TELEGRAM_BOT_TOKEN": token = value
            case "TELEGRAM_ALLOWED_USERS": users = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
        }
        guard !token.isEmpty, let first = users.first else { return nil }
        return "telegram:\(first)"
    }

    /// Telegram's message limit is 4096 characters; keep the notes under it.
    public static func trimmed(_ notes: String, limit: Int = 3800) -> String {
        guard notes.count > limit else { return notes }
        return String(notes.prefix(limit)) + "\n…"
    }

    public static let system = """
    You deliver meeting notes. Call the send_message tool exactly once with the \
    target given and the notes as the message text, unchanged. Then reply with \
    the single word SENT, or FAILED and one line why. Do nothing else.
    """

    public static func user(target: String, notes: String) -> String {
        "target: \(target)\n\n<notes>\n\(trimmed(notes))\n</notes>"
    }

    // MARK: Whether to send at all

    /// Why a meeting's notes are or are not going to Telegram. The first
    /// real meeting sent them without being asked — the only condition was
    /// that `TELEGRAM_ALLOWED_USERS` happened to exist — and then failed
    /// silently. Sending a meeting's notes off the Mac is a decision the
    /// user makes once, on purpose, in Settings.
    public enum Gate: Equatable, Sendable {
        /// The switch is off. This is the default and it says nothing.
        case off
        /// Switched on, but Hermes has no bot token or no allowed user.
        case notConfigured
        /// Switched on and configured, but the brain is not reachable.
        case notConnected
        case send(target: String)

        public var isSending: Bool { if case .send = self { return true } else { return false } }

        /// What the panel says while (or instead of) sending. Empty for
        /// `off`: a switch the user left alone needs no commentary.
        public var message: String {
            switch self {
            case .off: return ""
            case .notConfigured: return "Notes not sent — no Telegram bot is connected."
            case .notConnected: return "Notes not sent — your AI is not connected."
            case .send: return "Sending the notes to your Telegram…"
            }
        }
    }

    public static func gate(enabled: Bool, target: String?, connected: Bool) -> Gate {
        guard enabled else { return .off }
        guard let target, !target.isEmpty else { return .notConfigured }
        guard connected else { return .notConnected }
        return .send(target: target)
    }

    /// The switch's own explanation in Settings, and whether it can be
    /// switched on at all.
    ///
    /// `on` is the *stored* setting, which the switch now shows even when
    /// no bot is connected — so a stored `true` with no bot has to say what
    /// it means, or a disabled switch sitting in the on position reads as a
    /// promise that notes are going out.
    public static func switchExplanation(target: String?, on: Bool = false) -> String {
        guard target != nil else {
            if on {
                return "This is on, but nothing is being sent: no Telegram bot is connected. "
                     + "Connect one (Settings › Connections) and the notes will start going to "
                     + "you again — switch this off first if that is not what you want. It needs "
                     + "a bot token and your own Telegram id in Hermes's allowed users; the notes "
                     + "only ever go to you."
            }
            return "Connect a Telegram bot first (Settings › Connections). This needs a bot token "
                 + "and your own Telegram id in Hermes's allowed users — the notes only ever go to you."
        }
        return "Off by default. When it is on, the notes go to you on Telegram at the end of a "
             + "meeting and to nobody else. It also needs Hermes's send_message tool to be available "
             + "to Alfie's brain, which it is not yet — see MEETING-MODE.md."
    }

    /// The observed failure: Hermes's messaging tools are not exposed to
    /// the `claude` child under the `claude-code` MCP profile, so the model
    /// is asked to call a tool it does not have and answers "FAILED: no
    /// send_message tool is available in this environment." "FAILED" on its
    /// own tells the user nothing they can act on.
    public static let missingToolNote =
        "Notes not sent — Alfie's brain has no send_message tool. Hermes does not expose its "
        + "messaging tools to the claude-code profile, so this cannot work until that profile "
        + "is given send_message (MEETING-MODE.md › Notes to Telegram)."

    static let missingToolPhrases = [
        "not available", "no send_message", "unavailable", "not found",
        "does not exist", "isn't available", "is not exposed", "no such tool", "cannot find",
    ]

    public static func looksLikeMissingTool(_ reply: String) -> Bool {
        let r = reply.lowercased()
        guard r.contains("send_message") || r.contains("send message") else { return false }
        return missingToolPhrases.contains { r.contains($0) }
    }

    /// The brain's reply → what the user is told. `SENT` is the only
    /// success; everything else says what actually went wrong.
    public static func outcome(reply: String) -> (sent: Bool, message: String) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("SENT") { return (true, "Notes sent to your Telegram.") }
        if looksLikeMissingTool(trimmed) { return (false, missingToolNote) }
        if trimmed.isEmpty { return (false, "Notes not sent to Telegram — your AI did not answer.") }
        return (false, "Notes not sent to Telegram: \(String(trimmed.prefix(160)))")
    }
}

// MARK: - The list of past meetings

/// What the Meetings tab shows for a meeting before you open it: a name, how
/// long it ran, and one line of what it was about. No paths — a person
/// looking for last Tuesday's call recognises it by its title and the time
/// of day, not by `~/.moe/meetings/2026-08-30-1415`.
public enum MeetingListing {
    /// The notes' own title when the brain wrote one, else the date it
    /// started: "Meeting · Aug 30, 2:15 PM". `locale`/`timeZone` are
    /// arguments so the tests do not depend on where the Mac is.
    public static func title(_ record: MeetingRecord,
                             locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
        let t = (record.notes?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return "Meeting · " + dateLabel(record.startedAt, locale: locale, timeZone: timeZone)
    }

    public static func dateLabel(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        // Two localised parts joined with a comma rather than one template:
        // the single template renders as "Aug 30 at 2:15 PM", and the list
        // wants the tighter "Aug 30, 2:15 PM". The order of day and month
        // and the 12/24-hour clock still follow the user's region.
        func part(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        return part("MMMd") + ", " + part("jmm")
    }

    /// The one line under the title: the first sentence of the summary, or
    /// why there is none. Never a path, never a stack of fields.
    public static func blurb(_ record: MeetingRecord, limit: Int = 120) -> String {
        if let summary = record.notes?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return firstSentence(summary, limit: limit)
        }
        if record.incomplete { return "Stopped early — transcript only." }
        if let why = record.summaryFailure?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
            return "No notes — \(why)."
        }
        return "Transcript only."
    }

    /// Up to the first `. ! ?`, and never longer than `limit` — cut on a
    /// word boundary with an ellipsis rather than mid-word.
    public static func firstSentence(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var sentence = flat
        if let end = flat.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            sentence = String(flat[...end])
        }
        guard sentence.count > limit else { return sentence }
        let cut = String(sentence.prefix(limit))
        guard let space = cut.lastIndex(of: " ") else { return cut + "…" }
        return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Newest first — the order the tab lists them in.
    public static func sorted(_ records: [MeetingRecord]) -> [MeetingRecord] {
        records.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Reading the folder

    /// What a meeting folder holds besides `meeting.json`. A directory with
    /// any of these in it was a meeting, whatever its record says.
    static let artefacts = ["transcript.txt", "summary.md", "system.wav", "mic.wav"]

    /// Every meeting in `directory`, newest first.
    ///
    /// Two things this does that reading each `meeting.json` in a
    /// `compactMap` did not:
    ///
    ///  1. **`folder` is where the record was found, not what it says.**
    ///     `meeting.json` is an ordinary file in the user's home; its
    ///     `folder` field is a claim. The tab keys the list on it, opens
    ///     the transcript through it and points Delete at it, so a record
    ///     naming a different meeting's folder read and deleted that other
    ///     meeting — and two records naming one folder gave the list two
    ///     rows with the same identity.
    ///  2. **A folder whose record cannot be read is still listed.** A
    ///     missing, truncated or corrupt `meeting.json` — Moe killed
    ///     mid-meeting, a disk that filled — used to make the whole meeting
    ///     vanish, leaving "None yet." over a directory full of recordings.
    ///     It comes back as a record that says why, dated from the folder
    ///     name, so it can be opened and deleted like any other.
    public static func load(directory: URL, fileManager fm: FileManager = .default) -> [MeetingRecord] {
        let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        var out: [MeetingRecord] = []
        for entry in children {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // Rebuilt on the caller's own `directory` rather than used as
            // handed back: asking for resource values makes the enumerator
            // return canonical URLs (/private/var, not /var), and the folder
            // then no longer sits under the `~/.moe/meetings` that
            // `deleteMeeting` checks it against.
            let child = directory.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            let json = child.appendingPathComponent("meeting.json")
            if var record = try? MeetingRecord.load(json) {
                record.folder = child.path
                out.append(record)
            } else if fm.fileExists(atPath: json.path)
                        || artefacts.contains(where: { fm.fileExists(atPath: child.appendingPathComponent($0).path) }) {
                out.append(recovered(folder: child, fileManager: fm))
            }
        }
        return sorted(out)
    }

    /// A meeting we know happened and nothing else: the folder name for the
    /// date, and a line saying why there is no more than that.
    static func recovered(folder: URL, fileManager fm: FileManager = .default) -> MeetingRecord {
        let named = MeetingFolder.date(from: folder.lastPathComponent)
        let created = (try? fm.attributesOfItem(atPath: folder.path)[.creationDate]) as? Date
        return MeetingRecord(startedAt: named ?? created ?? Date.distantPast,
                             durationSeconds: 0, folder: folder.path,
                             summaryFailure: "Alfie could not read this meeting's record")
    }
}

// MARK: - The transcript, on screen

/// Reading `transcript.txt` for the Meetings tab.
///
/// A transcript grows with the meeting — an hour of two people is tens of
/// kilobytes, but nothing caps a recording left running all day, and the
/// detail view puts the whole string into one `Text` inside a `ScrollView`.
/// SwiftUI lays that out in one pass on the main thread: a few megabytes of
/// it is a beachball, not a slow scroll. So the view gets a bounded read and
/// a line saying where the rest is.
public enum TranscriptFile {
    /// Roughly a six-hour meeting's worth of text — past anything a person
    /// reads in a scroll view, and small enough to lay out instantly.
    public static let maxBytes = 256 * 1024

    public static let truncationNote =
        "\n\n… this is the first part of a long transcript. All of it is in transcript.txt, in the meeting's folder."

    /// `transcriptFile` off a record, trusted only as far as a plain file
    /// name inside the meeting's own folder — it comes out of a file on
    /// disk, and "../../.ssh/id_rsa" is a name a text field accepts.
    public static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        guard !base.isEmpty, !base.contains("/"), base != ".", base != ".." else { return "transcript.txt" }
        return base
    }

    /// Up to `maxBytes` of a UTF-8 text file, with the note appended when
    /// there was more. Missing or unreadable is "" — the view says so.
    public static func read(_ url: URL, maxBytes: Int = maxBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxBytes + 1), !data.isEmpty else { return "" }
        let truncated = data.count > maxBytes
        if truncated { data = data.prefix(maxBytes) }
        // A cut at a byte offset can land inside a multi-byte scalar; back
        // off up to three bytes rather than hand the view an empty string.
        var text: String?
        for drop in 0...3 where text == nil {
            guard data.count > drop else { break }
            text = String(data: data.prefix(data.count - drop), encoding: .utf8)
        }
        guard let text else { return "" }
        return truncated ? text + truncationNote : text
    }
}
