import Foundation

// Phase B, first half (MEETING-MODE.md): the people on the invite, and how
// far they can honestly be matched to the voices the diarizer separated.
//
// Everything here is pure — plain structs in, plain structs out, no
// EventKit, no files, no clock. The one EventKit call lives at the edge
// (Sources/Moe/Meeting/MeetingCalendar.swift) and does nothing but fill in
// `MeetingAttendee` values, so the whole rule below is unit-tested without
// Calendar access and behaves identically when there is none: no
// attendees is the same path as no grant, and both leave the transcript
// exactly as it reads today.
//
// The governing rule: **a wrong name is worse than "speaker 2"**. The
// invite says who was asked to the meeting. It does not say who turned up,
// who spoke, or which voice is which. So a name is only ever emitted when
// there is exactly one person it can belong to; anything else is carried
// as candidates for the user to confirm and shows as `speaker 2` until
// they do.

// MARK: - Who was invited

/// One person on the calendar invite, as far as the calendar knows them.
/// Both fields are optional because both are: a participant can arrive
/// with a display name and no address, or an address and no name.
public struct MeetingAttendee: Equatable, Codable, Sendable {
    public var name: String?
    public var email: String?
    /// The calendar says this participant is the person whose Mac this is.
    /// Their voice is the mic stream — `you` — and never a diarized cluster.
    public var isSelf: Bool
    /// Kept for the record only; the organiser is very often the user, but
    /// "organiser" is not evidence of that on its own.
    public var isOrganiser: Bool

    public init(name: String? = nil, email: String? = nil, isSelf: Bool = false, isOrganiser: Bool = false) {
        self.name = name
        self.email = email
        self.isSelf = isSelf
        self.isOrganiser = isOrganiser
    }

    /// What to call this person, or nil when the invite does not say.
    ///
    /// The display name first; the address only as a fallback, and only
    /// when a person's name can be read out of it without guessing
    /// (`MeetingAttendee.name(fromEmail:)`).
    /// Everything that comes back from here has been through
    /// `SpeakerNameBook.clean`: a display name is an arbitrary string off
    /// somebody else's calendar server, and it ends up in a transcript
    /// whose grammar is `[mm:ss] who: text`.
    public var displayName: String? {
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Calendars routinely put the address in the name field. Then
            // it is an address, and it goes through the address rules.
            if !t.isEmpty, !t.contains("@") { return SpeakerNameBook.clean(t) }
            if !t.isEmpty, t.contains("@") {
                return SpeakerNameBook.clean(Self.name(fromEmail: t) ?? Self.name(fromEmail: email ?? ""))
            }
        }
        return SpeakerNameBook.clean(Self.name(fromEmail: email ?? ""))
    }

    /// Local parts that are a role, a room or a robot rather than a person.
    /// Naming a voice "Info" is exactly the kind of wrong name this whole
    /// module exists to avoid.
    static let roleAddresses: Set<String> = [
        "info", "admin", "administrator", "noreply", "no-reply", "donotreply", "do-not-reply",
        "support", "hello", "hi", "team", "sales", "contact", "help", "office", "billing",
        "accounts", "accounting", "hr", "it", "reception", "invite", "invites", "invitation",
        "calendar", "calendars", "meeting", "meetings", "events", "notifications", "notification",
        "room", "rooms", "conf", "conference", "zoom", "meet", "webex", "teams", "mail", "email",
        "postmaster", "mailer-daemon", "bot", "notifier", "scheduler", "assistant",
    ]

    /// A person's name read out of an address — `dan.levy@acme.com` →
    /// "Dan Levy" — or nil when the address does not carry one.
    ///
    /// Deliberately narrow. It declines on: role and no-reply addresses, a
    /// local part with no letters, one that is a long unbroken blob (a
    /// calendar UID, a hash), and more than four parts. An initial (a
    /// one-letter part) is dropped rather than spelled out, so `j.smith`
    /// is "Smith" and not "J Smith"; if nothing but initials is left, the
    /// answer is nil.
    public static func name(fromEmail raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "mailto:", options: [.caseInsensitive, .anchored]) { s = String(s[r.upperBound...]) }
        guard !s.isEmpty else { return nil }
        var local = s.contains("@") ? String(s[..<s.firstIndex(of: "@")!]) : s
        if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        local = local.trimmingCharacters(in: .whitespaces)
        guard !local.isEmpty else { return nil }
        guard !roleAddresses.contains(local.lowercased()), !local.lowercased().contains("noreply") else { return nil }

        let rawParts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        guard !rawParts.isEmpty, rawParts.count <= 4 else { return nil }
        var parts: [String] = []
        for raw in rawParts {
            // "dan2" → "dan": a disambiguating digit is not part of a name.
            var part = String(raw)
            while let last = part.last, last.isNumber { part.removeLast() }
            guard !part.isEmpty else { continue }                 // an all-digit part
            guard part.count <= 20 else { return nil }            // a blob, not a name
            guard part.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
            guard part.count > 1 else { continue }                // an initial
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        // Again on what is left: `room4` is "room" once the numbering is
        // off, and a room is not somebody who spoke.
        guard !parts.contains(where: { roleAddresses.contains($0.lowercased()) }) else { return nil }
        return parts.map(capitalised).joined(separator: " ")
    }

    /// "dan" → "Dan"; "McDonald" is left as it is — an address that already
    /// carries capitals carries them on purpose.
    static func capitalised(_ part: String) -> String {
        guard part == part.lowercased() else { return part }
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    /// Case- and space-insensitive, for "is this the same person".
    static func fold(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Which event

/// One calendar event, flattened to what naming needs. The EventKit read
/// fills these in; the choosing rule below is pure.
public struct CalendarEventInfo: Equatable, Codable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendees: [MeetingAttendee]

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false,
                attendees: [MeetingAttendee] = []) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
    }
}

public enum MeetingCalendar {
    /// How early a meeting may be started and still count as being "in"
    /// the event that is about to begin. People press record while the
    /// others are still joining.
    public static let graceSeconds: Double = 5 * 60

    /// The event a meeting starting at `now` is, or nil.
    ///
    /// The rules, in order:
    ///
    ///  * **All-day events never win.** "Vacation", "Sprint 14", a
    ///    birthday: they cover every meeting of the day and name nobody.
    ///  * An event that is **actually running** beats one that has not
    ///    started yet (within the grace window) or has just ended.
    ///  * Among those, one **with attendees** beats one without — a
    ///    two-hour "Focus" block does not shadow the 10:00 call inside it.
    ///  * Then the **shortest**, which is the most specific of overlapping
    ///    events, then the one that started **latest**, then by title so
    ///    the answer never depends on the order EventKit happened to
    ///    return.
    public static func pick(from events: [CalendarEventInfo], at now: Date,
                            grace: Double = graceSeconds) -> CalendarEventInfo? {
        let live = events.filter { !$0.isAllDay && $0.end > now }
        let covering = live.filter { $0.start <= now }
        let soon = live.filter { $0.start > now && $0.start.timeIntervalSince(now) <= grace }
        let pool = covering.isEmpty ? soon : covering
        guard !pool.isEmpty else { return nil }
        return pool.sorted { a, b in
            let ap = a.attendees.isEmpty, bp = b.attendees.isEmpty
            if ap != bp { return !ap }
            let ad = a.end.timeIntervalSince(a.start), bd = b.end.timeIntervalSince(b.start)
            if ad != bd { return ad < bd }
            if a.start != b.start { return a.start > b.start }
            return a.title < b.title
        }.first
    }
}

// MARK: - Asking for the calendar, at the moment it would have helped

/// Whether to offer Calendar access, and when.
///
/// Everything else in this file is machinery for putting names on voices,
/// and on this Mac it has never once run: `moe.log` carries no "calendar
/// event …" line in its whole history, because Calendar access was never
/// granted. The 14:00 meeting on 2026-09-08 therefore saved seven speakers
/// with seven empty candidate lists, and its notes name people by whatever
/// the recogniser heard — "Louis" and "Louie", "Marianne" and "Marion", four
/// labels for two people.
///
/// The offer to fix that exists (`MeetingInvite.offer`) and it lives in the
/// Meetings pane, which is not where anybody goes while wondering who
/// "speaker 4" was. So it is now asked where the question is: on the panel
/// that has just finished showing a transcript full of numbers.
///
/// **Never while a meeting is starting or running.** A permission sheet in
/// the middle of joining a call is the wrong moment, and a recording has to
/// start whatever the answer would have been. Once the notes are written
/// there is nothing left to interrupt.
public enum CalendarNameOffer {

    /// Offer once, after a meeting that had voices a calendar could have
    /// named, and only while the answer is still open.
    ///
    /// `accessUndecided` means never asked. Refused is not asked again —
    /// that was an answer, and repeating it is nagging; the Meetings pane
    /// keeps its own line pointing at System Settings for anyone who
    /// changes their mind.
    public static func shouldOffer(unnamedVoices: Int, accessUndecided: Bool, alreadyAsked: Bool) -> Bool {
        unnamedVoices >= 1 && accessUndecided && !alreadyAsked
    }

    /// How many voices in a finished meeting are still only a number.
    public static func unnamedVoices(_ record: MeetingRecord) -> Int {
        let named = Set(record.speakerNames.compactMap { $0.name == nil ? nil : $0.speaker })
        return record.speakers.filter { !named.contains($0) }.count
    }

    public static func text(unnamedVoices n: Int) -> String {
        "Moe heard \(n) other \(n == 1 ? "voice" : "voices") and could not put "
            + "\(n == 1 ? "a name" : "names") to \(n == 1 ? "it" : "them"). Reading who was "
            + "invited would fix that — for this meeting and the next."
    }
}

// MARK: - Names against voices

/// How sure Moe is that a voice belongs to a name.
public enum SpeakerNameConfidence: String, Codable, Sendable {
    /// The user said so. Nothing overrides this.
    case confirmed
    /// One person was invited besides you, and one other voice was heard.
    /// The only mapping there is.
    case likely
    /// More than one person it could be — or none. Nothing is shown; the
    /// transcript still says "speaker 2".
    case unsure
}

public enum SpeakerNameSource: String, Codable, Sendable {
    case calendar
    case user
}

/// One diarized voice and what is known about whose it is.
public struct SpeakerName: Equatable, Codable, Sendable {
    /// The diarizer's cluster, the N in `them (speaker N)`.
    public var speaker: Int
    /// The name to use everywhere, or nil while it is not known. Only ever
    /// set for `.likely` and `.confirmed`.
    public var name: String?
    /// Who it could be, when it cannot be pinned down. Carried so the user
    /// picks from a list instead of typing, and so a later pass (voice
    /// memory) can narrow it.
    public var candidates: [String]
    public var confidence: SpeakerNameConfidence
    public var source: SpeakerNameSource

    public init(speaker: Int, name: String? = nil, candidates: [String] = [],
                confidence: SpeakerNameConfidence = .unsure, source: SpeakerNameSource = .calendar) {
        self.speaker = speaker
        self.name = name
        self.candidates = candidates
        self.confidence = confidence
        self.source = source
    }

    /// What a person sees for this voice: the name once there is one,
    /// else "Speaker 2". Never a cluster id, never an engine word.
    public var label: String { name ?? "Speaker \(speaker)" }
}

/// Cluster → name for a whole meeting: what the transcript, the notes and
/// the Meetings pane all read from.
public struct SpeakerNameBook: Equatable, Codable, Sendable {
    public var names: [SpeakerName]

    /// Words the transcript's own grammar already uses. A voice called
    /// "you" would write lines that read as the user's and that nothing
    /// can parse back, so the name is refused however it arrived.
    public static let reserved: Set<String> = ["you", "them", "me", "i"]

    /// Longer than any name a person is called, short enough that a
    /// transcript line stays a transcript line.
    public static let maxNameLength = 60

    /// **The one gate every name passes through**, wherever it came from:
    /// a calendar invite, a person typing in the Meetings pane, or a later
    /// source that does not exist yet.
    ///
    /// A name lands in `[mm:ss] <name>: text`, so the grammar of that line
    /// is the whole of this rule. Newlines, carriage returns and other
    /// control characters would split one line into two — neither of them
    /// a transcript line — so they are folded to spaces and runs of
    /// whitespace collapse. A colon is refused outright rather than
    /// folded: `": "` inside a name moves where a reader splits `who` from
    /// the words, and a name is not the place to be clever. Reserved
    /// words, blanks and anything past `maxNameLength` are refused too.
    ///
    /// Refusing is safe here in a way it is not everywhere: an unusable
    /// name means the voice keeps its number, which is the outcome this
    /// whole module defaults to anyway.
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var folded = ""
        folded.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            // Unicode's control, format and surrogate categories: newline
            // and carriage return among them, and also the bidi and
            // zero-width marks that make a name display as something other
            // than what it is.
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                folded.unicodeScalars.append(" ")
            } else {
                folded.unicodeScalars.append(scalar)
            }
        }
        let name = folded.split(separator: " ").joined(separator: " ")
        guard !name.isEmpty, name.count <= maxNameLength, !name.contains(":") else { return nil }
        guard !reserved.contains(MeetingAttendee.fold(name)) else { return nil }
        return name
    }

    public static func isUsable(_ name: String) -> Bool { clean(name) != nil }

    public init(names: [SpeakerName] = []) {
        self.names = names.sorted { $0.speaker < $1.speaker }
    }

    public var isEmpty: Bool { names.isEmpty }
    /// True when at least one voice actually has a name — the only case in
    /// which anything about the transcript changes.
    public var hasNames: Bool { names.contains { $0.name != nil } }

    public func entry(for speaker: Int) -> SpeakerName? { names.first { $0.speaker == speaker } }

    /// The name a transcript may be written with — through `clean` on the
    /// way out as well as on the way in, because a book can also arrive by
    /// decoding a `meeting.json` that somebody edited by hand.
    public func name(for speaker: Int) -> String? { Self.clean(entry(for: speaker)?.name) }

    /// The transcript's `who`: `you`, a name, or `them (speaker 2)`.
    public func label(for speaker: Speaker) -> String {
        guard case .them(let n?) = speaker, let name = name(for: n) else { return speaker.label }
        return name
    }

    /// The reverse, for reading a transcript that was written with names
    /// back into numbered speakers. Later entries never shadow earlier
    /// ones, so a duplicate name maps to the first voice that had it.
    public func speaker(named who: String) -> Int? {
        let key = MeetingAttendee.fold(who)
        for entry in names {
            if let n = entry.name, MeetingAttendee.fold(n) == key { return entry.speaker }
        }
        return nil
    }

    /// The user's own correction: final, whatever the calendar thought.
    /// `nil` puts the voice back to "speaker N" (the "not sure" case).
    public mutating func assign(_ name: String?, to speaker: Int) {
        let value = Self.clean(name)
        var entry = entry(for: speaker) ?? SpeakerName(speaker: speaker)
        entry.name = value
        entry.confidence = value == nil ? .unsure : .confirmed
        entry.source = .user
        if let value, !entry.candidates.contains(value) { entry.candidates.append(value) }
        names.removeAll { $0.speaker == speaker }
        names.append(entry)
        names.sort { $0.speaker < $1.speaker }
    }
}

public enum SpeakerNaming {

    /// The names on the invite that could belong to a diarized voice:
    /// everyone who is not the user, has a name at all, in invite order,
    /// each name once.
    ///
    /// Someone is "you" when the calendar says so (`isSelf`) or when their
    /// display name is exactly the name Moe knows the user by. Exactly —
    /// not a first-name match: a first-name match would delete "Dan Roth"
    /// from a meeting owned by a Dan, and deleting the only other attendee
    /// is how a confident mapping onto the *wrong* remaining person gets
    /// made.
    public static func nameable(attendees: [MeetingAttendee], youName: String? = nil) -> [String] {
        let you = youName.map(MeetingAttendee.fold).flatMap { $0.isEmpty ? nil : $0 }
        var seen = Set<String>()
        var out: [String] = []
        for attendee in attendees {
            guard !attendee.isSelf, let name = attendee.displayName else { continue }
            let key = MeetingAttendee.fold(name)
            guard !key.isEmpty, key != you, !seen.contains(key),
                  SpeakerNameBook.isUsable(name) else { continue }
            seen.insert(key)
            out.append(name)
        }
        return out
    }

    /// The whole rule, and the only place a name is ever attached to a
    /// voice from the invite alone.
    ///
    /// `clusters` is `Timeline.speakerNumbers` — the voices diarization
    /// separated on the *system* stream. The mic stream is the user and is
    /// never in there, so every cluster is somebody else.
    ///
    ///   * **One name, one voice** → that voice is that person. This is the
    ///     one unambiguous case, and it is the common one: a one-to-one.
    ///   * **Anything else** → no name at all, and every voice carries the
    ///     whole list of possibilities. Two attendees and two voices is
    ///     *not* solvable: the invite has no order, and guessing has a 50 %
    ///     chance of putting the wrong person's words in the notes.
    ///   * **No names on the invite** (no event, no attendees, access
    ///     denied, everyone is you) → an empty book, and everything reads
    ///     exactly as it does today.
    ///
    /// A book is returned for every cluster even when nothing is known, so
    /// the Meetings pane has a row to rename and the record has a place to
    /// remember it.
    public static func match(clusters: [Int], attendees: [MeetingAttendee],
                             youName: String? = nil) -> SpeakerNameBook {
        let voices = Array(Set(clusters)).sorted()
        guard !voices.isEmpty else { return SpeakerNameBook() }
        let names = nameable(attendees: attendees, youName: youName)
        guard !names.isEmpty else {
            return SpeakerNameBook(names: voices.map { SpeakerName(speaker: $0) })
        }
        if names.count == 1, voices.count == 1 {
            return SpeakerNameBook(names: [SpeakerName(speaker: voices[0], name: names[0],
                                                       candidates: names, confidence: .likely,
                                                       source: .calendar)])
        }
        return SpeakerNameBook(names: voices.map {
            SpeakerName(speaker: $0, name: nil, candidates: names, confidence: .unsure, source: .calendar)
        })
    }

    /// One line for the Meetings pane, in a person's words. Empty when
    /// there is nothing worth saying — which is most of the time.
    public static func explanation(_ book: SpeakerNameBook) -> String {
        let unnamed = book.names.filter { $0.name == nil }
        guard !unnamed.isEmpty else { return "" }
        if unnamed.contains(where: { !$0.candidates.isEmpty }) {
            return "Moe knows who was invited but not which voice is which — pick a name and it is used everywhere in this meeting."
        }
        return "Name a voice and it is used everywhere in this meeting."
    }
}

// MARK: - Renaming, after the fact

public enum SpeakerRename {

    /// The forms a voice's old label takes in text somebody else wrote —
    /// the model's summary says "speaker 2", the transcript said
    /// "them (speaker 2)".
    static func oldLabels(speaker n: Int) -> [String] {
        ["them (speaker \(n))", "speaker \(n)", "Speaker \(n)"]
    }

    /// A record and its transcript with one voice renamed.
    ///
    /// What is rewritten, and what deliberately is not:
    ///
    ///  * **The transcript** — line by line, and only the `who` part of a
    ///    line it can read (`relabelled`). A line it cannot read is passed
    ///    through byte for byte.
    ///  * **The notes' `who` fields** — an action item owned by
    ///    "speaker 2", or by the name the calendar guessed wrong, becomes
    ///    the corrected one.
    ///  * **"speaker 2" wherever else it appears** in the notes and in
    ///    `summary.md`, because that string is never anything but this.
    ///
    ///  * A *name* in prose is left alone. Correcting "Dan" to "Dan Roth"
    ///    must not rewrite a sentence that mentions a different Dan, and
    ///    the summary is a paragraph of English, not a field. Getting the
    ///    labels right and the prose untouched is the honest half.
    public static func apply(record: MeetingRecord, transcript: String, summary: String?,
                             speaker n: Int, to name: String?)
        -> (record: MeetingRecord, transcript: String, summary: String?) {
        var record = record
        var book = SpeakerNameBook(names: record.speakerNames)
        let previous = book.name(for: n)
        book.assign(name, to: n)
        record.speakerNames = book.names

        // The transcript: read with what it was written with, written with
        // what it is now — and nothing else about the file touched.
        var oldBook = SpeakerNameBook(names: record.speakerNames)
        oldBook.assign(previous, to: n)
        let rewritten = relabelled(transcript, from: oldBook, to: book)

        // What the book actually took — a name it refused (empty, or one of
        // the transcript's own words) leaves everything else alone.
        guard let name = book.name(for: n) else { return (record, rewritten, summary) }
        if var notes = record.notes {
            notes.title = replacing(notes.title, speaker: n, with: name)
            notes.summary = replacing(notes.summary, speaker: n, with: name)
            notes.decisions = notes.decisions.map { replacing($0, speaker: n, with: name) }
            notes.openQuestions = notes.openQuestions.map { replacing($0, speaker: n, with: name) }
            notes.actionItems = notes.actionItems.map { item in
                var item = item
                // The owner field is a label, so the old *name* counts here
                // as well as the numbered form.
                if let previous, MeetingAttendee.fold(item.who) == MeetingAttendee.fold(previous) {
                    item.who = name
                } else {
                    item.who = replacing(item.who, speaker: n, with: name)
                }
                item.what = replacing(item.what, speaker: n, with: name)
                item.when = replacing(item.when, speaker: n, with: name)
                return item
            }
            record.notes = notes
        }
        return (record, rewritten, summary.map { replacing($0, speaker: n, with: name) })
    }

    // MARK: The transcript

    /// A transcript with its speaker labels rewritten from one book to
    /// another, **incapable of losing a line**.
    ///
    /// The obvious implementation — parse the whole file, format it again —
    /// is not safe here, and the reason is worth keeping: `Timeline.parse`
    /// skips a line it cannot read, so a single unreadable line among fifty
    /// would be *deleted from the user's meeting record* by an operation as
    /// routine as correcting a name. And there are several ways in: a
    /// transcript the user hand-edited (these are plain files we tell them
    /// they own), a line from an older shape of the format, or a name that
    /// slipped through carrying a `": "` before `SpeakerNameBook.clean`
    /// existed.
    ///
    /// So this walks lines, and on each one changes *only* the `who`
    /// substring — never the timestamp, the spacing or the words, and
    /// never a line it cannot read. Splitting on "\n" and joining on "\n"
    /// round-trips exactly, so blank lines and the trailing newline survive
    /// too. The guarantee is not "the rewrite is correct" but "a line this
    /// cannot round-trip is left exactly as it was found".
    public static func relabelled(_ transcript: String, from old: SpeakerNameBook,
                                  to new: SpeakerNameBook) -> String {
        transcript.components(separatedBy: "\n").map { line -> String in
            guard let range = whoRange(in: line),
                  let speaker = speaker(String(line[range]), names: old) else { return line }
            let label = new.label(for: speaker)
            guard label != String(line[range]) else { return line }
            return line.replacingCharacters(in: range, with: label)
        }.joined(separator: "\n")
    }

    /// Where the `who` sits in `[mm:ss] who: text`, or nil when the line is
    /// not one of ours. Deliberately the same shape `Timeline.parse`
    /// accepts, expressed as a range into the original line so everything
    /// around it survives untouched.
    static func whoRange(in line: String) -> Range<String.Index>? {
        guard let open = line.firstIndex(of: "["), line[..<open].allSatisfy(\.isWhitespace),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let stamp = line[line.index(after: open)..<close]
        let parts = stamp.split(separator: ":")
        guard parts.count == 2, Int(parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        let after = line.index(after: close)
        guard after <= line.endIndex, let colon = line[after...].range(of: ": ") else { return nil }
        var start = after
        while start < colon.lowerBound, line[start].isWhitespace { start = line.index(after: start) }
        var end = colon.lowerBound
        while end > start, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
        guard start < end else { return nil }
        return start..<end
    }

    /// The voice a `who` names, under a given book, or nil.
    static func speaker(_ who: String, names: SpeakerNameBook) -> Speaker? {
        if who == "you" { return .you }
        if who == "them" { return .them(nil) }
        if who.hasPrefix("them (speaker "), who.hasSuffix(")"),
           let n = Int(who.dropFirst("them (speaker ".count).dropLast()) { return .them(n) }
        if let n = names.speaker(named: who) { return .them(n) }
        return nil
    }

    // MARK: The notes

    /// `"speaker 2"` → `"Sam"` in text the model wrote, on whole words only.
    ///
    /// The bound matters at two digits: without it, renaming speaker 1
    /// turns every "speaker 12" in the notes into "Dan2". A match is taken
    /// only when neither neighbour is a letter or a digit, which leaves
    /// "them (speaker 12)" alone while renaming speaker 1 and still catches
    /// "speaker 2." at the end of a sentence.
    ///
    /// What this cannot rule out is a summary that uses those words as
    /// ordinary English — "the second speaker 2 minutes in". It is
    /// contrived, and the cost if it ever happens is one wrong word in one
    /// sentence, not a lost line; `relabelled` is where the guarantee is.
    static func replacing(_ text: String, speaker n: Int, with name: String) -> String {
        var out = text
        for label in oldLabels(speaker: n) {
            out = replacingWholeWords(out, label, with: name)
        }
        return out
    }

    static func replacingWholeWords(_ text: String, _ needle: String, with name: String) -> String {
        guard !needle.isEmpty else { return text }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        var out = ""
        var from = text.startIndex
        while let found = text.range(of: needle, range: from..<text.endIndex) {
            out += text[from..<found.lowerBound]
            let beforeOK = found.lowerBound == text.startIndex || !isWord(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex || !isWord(text[found.upperBound])
            out += (beforeOK && afterOK) ? name : String(text[found])
            from = found.upperBound
        }
        out += text[from...]
        return out
    }
}
