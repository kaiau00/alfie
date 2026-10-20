import Foundation

/// What the brain returns for a meeting, and what `summary.md` and
/// `meeting.json` are made of. Parsing is tolerant — a model wraps JSON in a
/// fence or a sentence often enough that refusing would lose the notes —
/// but never invents: a reply with no usable object is `nil`, and the
/// transcript is kept either way.
public struct MeetingNotes: Equatable, Codable, Sendable {
    public struct ActionItem: Equatable, Codable, Sendable {
        public var who: String
        public var what: String
        public var when: String
        /// Ticked in the Meetings tab: a Reminder was created for it.
        /// Optional so records written before it existed still load.
        public var reminded: Bool?
        public init(who: String, what: String, when: String) {
            self.who = who; self.what = what; self.when = when
        }
        public var line: String {
            var s = "- **\(who.isEmpty ? "Someone" : who)**: \(what)"
            if !when.isEmpty { s += " — by \(when)" }
            return s
        }
    }

    public var title: String
    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    /// Work the meeting said needs doing that nobody took on. Without this
    /// bucket a need stated four times over forty minutes — "we're going to
    /// need monitoring if we're managing a hundred of these" — is not a
    /// decision, not an open question, and not anybody's action item, so it
    /// falls out of the notes entirely and the transcript is the only place
    /// it survives.
    public var todos: [String]
    public var openQuestions: [String]

    public init(title: String, summary: String, decisions: [String] = [],
                actionItems: [ActionItem] = [], todos: [String] = [],
                openQuestions: [String] = []) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.todos = todos
        self.openQuestions = openQuestions
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions, todos
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    /// `todos` arrived after records were already on disk, so it decodes as
    /// absent rather than failing the whole notes object — a record written
    /// before it existed still describes a real meeting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Meeting"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        todos = try c.decodeIfPresent([String].self, forKey: .todos) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
    }

    /// The brain's reply as notes, or nil. Accepts the bare object, a
    /// ```json fence, or an object embedded in prose (first `{` to the last
    /// `}`); every field is optional except that at least a title or a
    /// summary must be there. Action items may be strings or objects.
    public static func parse(_ reply: String) -> MeetingNotes? {
        guard let obj = jsonObject(in: reply) else { return nil }
        let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (obj["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !summary.isEmpty else { return nil }
        func strings(_ key: String) -> [String] {
            ((obj[key] as? [Any]) ?? []).compactMap { item -> String? in
                let s: String
                if let t = item as? String { s = t }
                else if let d = item as? [String: Any] {
                    s = (d["text"] as? String) ?? (d["decision"] as? String) ?? (d["question"] as? String) ?? ""
                } else { return nil }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
        }
        let actions = ((obj["action_items"] as? [Any]) ?? (obj["actionItems"] as? [Any]) ?? []).compactMap { item -> ActionItem? in
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : ActionItem(who: "", what: t, when: "")
            }
            guard let d = item as? [String: Any] else { return nil }
            let what = ((d["what"] as? String) ?? (d["task"] as? String) ?? (d["action"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty else { return nil }
            return ActionItem(who: ((d["who"] as? String) ?? (d["owner"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              what: what,
                              when: ((d["when"] as? String) ?? (d["due"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return MeetingNotes(title: title.isEmpty ? "Meeting" : title, summary: summary,
                            decisions: strings("decisions"), actionItems: actions,
                            todos: strings("todos") + strings("to_do") + strings("needs_doing"),
                            openQuestions: strings("open_questions") + strings("openQuestions"))
    }

    static func jsonObject(in reply: String) -> [String: Any]? {
        func decode(_ s: Substring) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = decode(trimmed[...]) { return o }
        guard let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close else { return nil }
        return decode(trimmed[open...close])
    }

    /// `summary.md`: the notes as markdown a person can read and edit.
    /// `bookmarks` are the moments the user marked; `footer` lines (drift
    /// note, off the record) go at the end, small.
    public func markdown(date: Date, duration: Double, bookmarks: [Bookmark] = [],
                         captures: [CaptureRecord] = [], footer: [String] = []) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var md = "# \(title)\n\n_\(f.string(from: date)) · \(Timeline.clock(duration))_\n\n"
        if !summary.isEmpty { md += "\(summary)\n\n" }
        if !decisions.isEmpty {
            md += "## Decisions\n\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !actionItems.isEmpty {
            md += "## Action items\n\n" + actionItems.map(\.line).joined(separator: "\n") + "\n\n"
        }
        if !todos.isEmpty {
            md += "## To do\n\n" + todos.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !openQuestions.isEmpty {
            md += "## Open questions\n\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !bookmarks.isEmpty {
            md += "## Bookmarks\n\n" + bookmarks.map { "- \($0.line)" }.joined(separator: "\n") + "\n\n"
        }
        if !captures.isEmpty {
            md += "## Screens\n\n" + captures.map { "- \($0.line)" }.joined(separator: "\n") + "\n\n"
        }
        let notes = footer.filter { !$0.isEmpty }
        if !notes.isEmpty { md += "---\n\n" + notes.map { "_\($0)_" }.joined(separator: "  \n") + "\n" }
        return md
    }
}

/// `meeting.json`: everything about one meeting that is not the audio or
/// the transcript text, for the Meetings pane and for the agent.
public struct MeetingRecord: Equatable, Codable, Sendable {
    public var startedAt: Date
    public var durationSeconds: Double
    public var folder: String
    public var transcriptFile: String
    public var summaryFile: String?
    public var notes: MeetingNotes?
    public var speakers: [Int]
    public var driftNote: String
    public var summarised: Bool
    /// Why there are no notes, when there are none ("brain unavailable").
    public var summaryFailure: String?
    public var recordingsDeleted: Bool
    /// Why `system.wav` and `mic.wav` are still here although the setting
    /// says delete them: the result looked like a capture failure and the
    /// audio is the only evidence of what went wrong (see `CaptureCheck`).
    public var recordingsKeptReason: String?
    /// The mirror of `recordingsKeptReason`: the result did look like a
    /// capture failure, and the recordings were deleted anyway because the
    /// meeting was past `CaptureCheck.keepCeilingSeconds`. Without this a
    /// person looking for the evidence later cannot tell "the rule never
    /// fired" from "the rule fired and the setting won".
    public var recordingsDeletedNote: String?
    /// Who took the notes: always the user's own agent, so it can later
    /// answer "what did we agree" from its own record.
    public var taker: String = "moe-agent"
    public var bookmarks: [Bookmark] = []
    public var offTheRecord: [PauseLog.Span] = []
    /// True when Moe quit (or was killed) while recording: the WAVs are
    /// closed and valid, `transcript.txt` has what the live pass wrote,
    /// and there are no notes.
    public var incomplete: Bool = false
    /// Who the calendar said was invited (Phase B). Empty when there was no
    /// event, no attendees, or no Calendar access — all ordinary.
    public var attendees: [MeetingAttendee] = []
    /// One entry per voice diarization separated, with the name if it is
    /// known and the candidates if it is not. This is where a later pass —
    /// voice memory across meetings — reads "cluster 2 of this meeting was
    /// Dan, and the user confirmed it" from, next to the audio it came out
    /// of. See `SpeakerNaming`.
    public var speakerNames: [SpeakerName] = []
    /// Screenshots and clips taken during the meeting, in order, with the
    /// reason each was taken and what the AI saw in it (`CaptureRecord`).
    public var captures: [CaptureRecord] = []
    /// The call app Moe noticed the meeting in ("Zoom"), when it was
    /// started from the offer rather than by hand.
    public var callApp: String?

    /// The names as one book, for formatting a transcript or labelling a row.
    public var nameBook: SpeakerNameBook { SpeakerNameBook(names: speakerNames) }

    public init(startedAt: Date, durationSeconds: Double, folder: String,
                transcriptFile: String = "transcript.txt", summaryFile: String? = nil,
                notes: MeetingNotes? = nil, speakers: [Int] = [], driftNote: String = "",
                summarised: Bool = false, summaryFailure: String? = nil, recordingsDeleted: Bool = false,
                bookmarks: [Bookmark] = [], offTheRecord: [PauseLog.Span] = []) {
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.folder = folder
        self.transcriptFile = transcriptFile
        self.summaryFile = summaryFile
        self.notes = notes
        self.speakers = speakers
        self.driftNote = driftNote
        self.summarised = summarised
        self.summaryFailure = summaryFailure
        self.recordingsDeleted = recordingsDeleted
        self.bookmarks = bookmarks
        self.offTheRecord = offTheRecord
    }

    /// Fields added after the first records were written are optional on
    /// the way in, so an older `meeting.json` still loads.
    ///
    /// Only the three fields every record has ever had are required. The
    /// rest are read with `try?`: a record whose `notes` or `bookmarks` are
    /// the wrong shape — an older writer, a hand edit, a half-written file —
    /// still describes a real meeting with a real transcript beside it, and
    /// losing the whole meeting from the tab over one bad key is worse than
    /// listing it without its notes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` on `decodeIfPresent` gives a doubly-optional; flatten it.
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil)
        }
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        folder = try c.decode(String.self, forKey: .folder)
        transcriptFile = opt(String.self, .transcriptFile) ?? "transcript.txt"
        summaryFile = opt(String.self, .summaryFile)
        notes = opt(MeetingNotes.self, .notes)
        speakers = opt([Int].self, .speakers) ?? []
        driftNote = opt(String.self, .driftNote) ?? ""
        summarised = opt(Bool.self, .summarised) ?? false
        summaryFailure = opt(String.self, .summaryFailure)
        recordingsDeleted = opt(Bool.self, .recordingsDeleted) ?? false
        recordingsKeptReason = opt(String.self, .recordingsKeptReason)
        recordingsDeletedNote = opt(String.self, .recordingsDeletedNote)
        taker = opt(String.self, .taker) ?? "moe-agent"
        bookmarks = opt([Bookmark].self, .bookmarks) ?? []
        offTheRecord = opt([PauseLog.Span].self, .offTheRecord) ?? []
        incomplete = opt(Bool.self, .incomplete) ?? false
        attendees = opt([MeetingAttendee].self, .attendees) ?? []
        speakerNames = opt([SpeakerName].self, .speakerNames) ?? []
        captures = opt([CaptureRecord].self, .captures) ?? []
        callApp = opt(String.self, .callApp)
    }

    enum CodingKeys: String, CodingKey {
        case startedAt, durationSeconds, folder, transcriptFile, summaryFile, notes, speakers, driftNote
        case summarised, summaryFailure, recordingsDeleted, recordingsKeptReason, recordingsDeletedNote
        case taker, bookmarks, offTheRecord, incomplete, attendees, speakerNames, captures, callApp
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func json() throws -> Data { try Self.encoder().encode(self) }
    public static func load(_ url: URL) throws -> MeetingRecord {
        try decoder().decode(MeetingRecord.self, from: Data(contentsOf: url))
    }
}

/// The folder name for a meeting: `2026-08-30-1415`, the spec's shape.
public enum MeetingFolder {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }

    public static func name(for date: Date) -> String {
        formatter().string(from: date)
    }

    /// The other direction, for a folder whose `meeting.json` cannot be
    /// read: the name is the only record of when the meeting was, and a
    /// meeting the list can date is a meeting the user recognises. The
    /// `-2` a same-minute collision adds is ignored.
    public static func date(from name: String) -> Date? {
        let stem = name.split(separator: "-").prefix(4).joined(separator: "-")
        return formatter().date(from: stem)
    }
}
