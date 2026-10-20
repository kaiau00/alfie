import Foundation

/// The one request a meeting makes of the brain. `Moe` implements it over
/// the Hermes endpoint on session key `moe-meeting`; the CLI and tests use
/// a stub. Throws when the brain cannot be reached; the summary then says
/// so and the transcript stands on its own.
public protocol MeetingBrain: Sendable {
    func complete(system: String, user: String) async throws -> String
}

public enum MeetingSummaryPrompt {
    public static let sessionKey = "moe-meeting"

    /// Fixed on purpose: a stable prompt keeps the Hermes session warm and
    /// the output shape predictable.
    public static let system = """
    You write meeting notes from a transcript. The transcript has one line per \
    utterance: a [mm:ss] time, then who spoke — "you" is the person whose notes \
    these are; "them (speaker N)" are the other participants, numbered by the \
    order they first spoke, and a participant Moe could identify is named \
    instead ("Dan:") — use that name — then the words. Recognition is imperfect: read \
    through misheard words, and never invent facts, names or dates that are \
    not in the transcript. Write in the language the meeting was held in.

    Reply with ONE JSON object and nothing else — no prose, no code fence — \
    with exactly these keys:
      "title": a short, specific title (under 8 words);
      "summary": two to five sentences on what the meeting was about and \
    where it landed;
      "decisions": an array of strings, one per decision actually made;
      "action_items": an array of objects {"who": …, "what": …, "when": …}, \
    who as named in the transcript ("you" for the note-taker), when as \
    spoken ("Tuesday", "end of month") or "" if none was given;
      "todos": an array of strings for work the meeting said needs doing \
    that nobody took on — a problem to fix, a thing to build, a capability \
    someone said they want. If a person took it on it is an action item and \
    does not belong here, but a stated need must land in one list or the \
    other; do not drop it because nobody's name was attached;
      "open_questions": an array of strings for what was raised and not settled.

    Read the whole transcript before you write any of this. A thing said \
    once in passing counts, and a thing said four times over the meeting is \
    among the most important in it — weight by how much it mattered to the \
    speakers, never by how near the end it was said. \
    \(MeetingChatter.rule) \
    One task belongs to one person: if the same commitment appears twice \
    under different names, decide who actually took it on and write it once. \
    Empty arrays are fine. Do not call any tool; the transcript is complete.
    """

    public static func user(transcript: String, date: Date, duration: Double, bookmarks: [Bookmark] = [],
                            captures: [CaptureRecord] = []) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var head = "Meeting on \(f.string(from: date)), \(Timeline.clock(duration)) long."
        let seen = captures.filter { !($0.caption ?? "").isEmpty }
        if !seen.isEmpty {
            head += """
            \n\nScreenshots were taken during the meeting; what each showed, described \
            by a vision model as the picture was taken, is below with its time. These \
            are evidence from the meeting exactly as the spoken words are — a slide, a \
            dashboard, a document, a design someone was walking through. Read them as \
            part of the record: if a screen carries a number, a decision, a name, a \
            metric or a task that the talking did not state outright, put it in the \
            notes and draw the conclusion from what was shown, not only from what was \
            said. When a point rests on a screen, say so (\u{201C}the Q3 slide showed…\u{201D}). \
            Do not invent detail the description does not contain.
            \(seen.map { "[\(Timeline.clock($0.at))] \($0.caption ?? "")" }.joined(separator: "\n"))
            """
        }
        if !bookmarks.isEmpty {
            head += """
            \n\nThe note-taker bookmarked these moments while listening; what was said \
            around each of them matters more than the rest — make sure the summary, \
            decisions and action items cover them:
            \(Bookmarks.promptLines(bookmarks))
            """
        }
        return """
        \(head)

        <transcript>
        \(transcript)
        </transcript>
        """
    }
}

/// The one request for the notes, asked more than once when it has to be.
///
/// A meeting is an hour of somebody's day and there is exactly one chance
/// to write it up, so a single bad answer must not be the end of it. On
/// 2026-09-08 the 16:10 meeting stopped at 21:12:30 and its notes were
/// recorded as failed at 21:12:45 — fifteen seconds later, for a 60 KB
/// transcript. That is not a model reading an hour of conversation and
/// giving up; that is an error coming straight back. The gateway's log had
/// why, sixteen minutes earlier: `claude-code session retired (turn error:
/// claude produced no output for 120s)`. The brain's session had died, Moe
/// asked it anyway, took the first thing it said as final, and a
/// sixty-one-minute meeting has no notes.
///
/// So: ask again. Both failures are worth a second attempt and for the same
/// reason — a retired session is replaced by a fresh one on the next
/// request, and a model that answered with prose usually answers with JSON
/// when asked again. The wait between them is what gives the child time to
/// come back up.
struct NotesRequest {
    let system: String
    let user: String
    /// Two attempts, not more. A third costs another two minutes of the
    /// user watching "Writing your notes…" for a brain that is plainly not
    /// answering, and the transcript is saved either way.
    var attempts = 2
    var pauseBetween: Duration = .seconds(3)
    /// Replaceable so the tests do not sleep.
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The reply and which attempt produced it. Throws only when every
    /// attempt threw — the last error, since it is the current state.
    ///
    /// A reply that arrives but is not notes is a failure *here*, not at
    /// the call site: the caller cannot ask again without knowing that, and
    /// leaving the judgement outside meant the retry could never see the
    /// case it exists for.
    func run(brain: MeetingBrain) async throws -> (reply: String, attempts: Int) {
        var lastError: Error?
        var lastReply: String?
        for attempt in 1...max(1, attempts) {
            if attempt > 1 { await sleep(pauseBetween) }
            do {
                let reply = try await brain.complete(system: system, user: user)
                if MeetingNotes.parse(reply) != nil { return (reply, attempt) }
                lastReply = reply
                lastError = nil
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        // Every attempt answered, none of them with notes: hand back the
        // last one so the record can quote it.
        return (lastReply ?? "", max(1, attempts))
    }

    /// A reply, short enough to sit in `meeting.json` and long enough to
    /// recognise. Whitespace flattened, because a stack trace or a wall of
    /// markdown wrapped over eight lines in the Meetings pane.
    static func excerpt(_ reply: String, limit: Int = 160) -> String {
        let flat = reply.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return "it was empty" }
        return flat.count <= limit ? "\u{201C}\(flat)\u{201D}"
                                   : "\u{201C}\(flat.prefix(limit))\u{2026}\u{201D}"
    }
}

/// Whether a finished meeting looks less like a quiet meeting and more like
/// a meeting Moe failed to hear.
///
/// The privacy default deletes `system.wav` and `mic.wav` once the notes
/// exist, which is right for a meeting that worked: a folder of recordings
/// of other people is a liability. It is exactly wrong for the case where
/// the recording is the only evidence left of why there is nothing to read
/// — the first real meeting produced one transcript line from 95 seconds of
/// talking and then deleted the audio that would have said why.
///
/// The bar is deliberately low: fewer than one line per 30 seconds. Real
/// meetings are far denser than that — even a mostly-silent one where the
/// user listens to somebody else clears it — so this keeps audio only when
/// something is plainly wrong.
///
/// That rate rule misses the one-sided case, and no rule on line counts can
/// catch it. A meeting where the far end transcribes and the microphone
/// produces nothing clears the rate on the far end's lines alone, so the
/// evidence of a dead or misrouted microphone is deleted — that happened on
/// the first controlled test. But "one side produced nothing" is also
/// exactly what a webinar looks like, where the user listened and said
/// nothing, and keeping *that* recording is 115 MB of other people held
/// against an explicit instruction to delete them. The two transcripts are
/// identical; only the levels tell them apart, so the second rule below
/// takes `ChannelEvidence` and asks whether the silent side was silent
/// because nothing was said on it or because nothing got through.
public enum CaptureCheck {
    /// A meeting should produce at least one transcript line per this many
    /// seconds. Below it, the result looks like a capture failure.
    public static let secondsPerLine: Double = 30

    /// How long a meeting may be and still have its audio kept against the
    /// delete setting.
    ///
    /// The rule had no ceiling, and without one it stops being "keep the
    /// evidence" and becomes "ignore the setting". Both streams are 16 kHz
    /// 16-bit mono, so a meeting costs **230 MB an hour**: a three-hour
    /// call keeps 690 MB and a recorder left running all day keeps 1.8 GB —
    /// of other people's voices, held against an explicit instruction to
    /// delete them.
    ///
    /// Thirty minutes, which is 115 MB. Three reasons for that number:
    ///
    ///   * it is the shape of meeting a silent capture actually gets
    ///     noticed on — a standup, a one-to-one, a call that went wrong
    ///     early; the one real instance was 95 seconds;
    ///   * 115 MB is a cost a person absorbs without noticing, and 230 MB
    ///     and up is not;
    ///   * nothing in a three-hour recording is needed to diagnose it that
    ///     is not in the first few minutes — a wrong device, a muted input
    ///     or a level under the gate is visible immediately — while the
    ///     other two hours and fifty minutes are pure liability.
    ///
    /// Above it the setting wins and the audio goes, but the record says
    /// that it went and that the result looked wrong, so the deletion is
    /// not silent.
    public static let keepCeilingSeconds: Double = 30 * 60

    /// Both streams together, bytes per second of meeting: 16 kHz × 16-bit
    /// mono × 2.
    public static let bytesPerSecond: Double = 64_000

    public static func looksLikeCaptureFailure(lines: Int, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return Double(lines) < duration / secondsPerLine
    }

    /// The rule as it is actually applied: it looks like a capture failure
    /// *and* the recording is short enough that keeping it is a favour
    /// rather than an imposition.
    public static func shouldKeepAudio(lines: Int, duration: Double) -> Bool {
        looksLikeCaptureFailure(lines: lines, duration: duration) && duration <= keepCeilingSeconds
    }

    // MARK: The one-sided case

    /// A stream that carried audio and produced not one transcript line.
    ///
    /// This is the whole of the second rule. `levels` nil — not measured —
    /// returns nil, which is what makes an older meeting, or any path that
    /// never collected levels, behave exactly as it did before: the rate
    /// rule alone decides. Missing data can only ever mean "no opinion",
    /// never "keep".
    ///
    /// How much audio counts as carried is `ChannelEvidence`'s to say, and
    /// it scales with the meeting — a twentieth of it, never under 15 s —
    /// so that a listener's typing and coughs cannot pass for a person who
    /// spoke and was not heard.
    ///
    /// Only *zero* lines counts. A side that produced two lines when it
    /// should have produced forty is a transcription problem the rate rule
    /// is already the judge of; a side that produced none while its
    /// microphone was live is the case where the transcript is not evidence
    /// of anything and the audio is.
    public static func silentChannel(segments: [Segment], duration: Double,
                                     levels: ChannelEvidence?) -> Suspicion? {
        guard let levels, duration > 0 else { return nil }
        let yours = segments.reduce(0) { $0 + ($1.speaker.isYou ? 1 : 0) }
        let theirs = segments.count - yours
        if yours == 0, levels.micCarriedAudio(over: duration) {
            return .silentChannel(.mic, otherLines: theirs, duration: duration)
        }
        if theirs == 0, levels.systemCarriedAudio(over: duration) {
            return .silentChannel(.system, otherLines: yours, duration: duration)
        }
        return nil
    }

    /// Why this meeting looks like a capture failure, or nil.
    ///
    /// The silent-channel verdict comes first when both fire: "your
    /// microphone carried audio and transcribed nothing" is the diagnosis,
    /// and "only two lines in ten minutes" is the symptom of it.
    public static func suspicion(segments: [Segment], duration: Double,
                                 levels: ChannelEvidence? = nil) -> Suspicion? {
        if let dead = silentChannel(segments: segments, duration: duration, levels: levels) { return dead }
        if looksLikeCaptureFailure(lines: segments.count, duration: duration) {
            return .tooFewLines(lines: segments.count, duration: duration)
        }
        return nil
    }

    /// Both rules, with the ceiling applied. The ceiling is the same for
    /// both: what makes 690 MB too much to keep is the size, not which
    /// rule asked for it.
    public static func shouldKeepAudio(segments: [Segment], duration: Double,
                                       levels: ChannelEvidence? = nil) -> Bool {
        suspicion(segments: segments, duration: duration, levels: levels) != nil
            && duration <= keepCeilingSeconds
    }

    /// Which of the two things makes a finished meeting look wrong, and
    /// every sentence that follows from it.
    public enum Suspicion: Equatable, Sendable {
        /// Too few transcript lines for the length of the recording.
        case tooFewLines(lines: Int, duration: Double)
        /// One stream carried audio above the noise floor and produced no
        /// transcript line at all; `otherLines` is what the other stream
        /// produced, which is the number that shows this was not simply a
        /// quiet meeting.
        case silentChannel(MeetingRecorder.Stream, otherLines: Int, duration: Double)

        /// The `recordingsKeptReason` written into `meeting.json` and shown
        /// in the Meetings pane.
        public var keptReason: String {
            switch self {
            case let .tooFewLines(lines, duration):
                return CaptureCheck.keptReason(lines: lines, duration: duration)
            case let .silentChannel(stream, otherLines, duration):
                return "kept despite the delete-after-notes setting: \(Self.side(stream)) carried "
                    + "audio above the noise floor during \(Timeline.clock(duration)) of recording "
                    + "and \(CaptureCheck.silentChannelMark), while \(Self.otherSide(stream)) "
                    + "produced \(otherLines) — audio that reached the recorder and not the "
                    + "transcript is a capture failure, not a quiet meeting, and the recording is "
                    + "the only evidence of it"
            }
        }

        /// The `recordingsDeletedNote`: it looked wrong, and the audio went
        /// anyway because the meeting was past the ceiling.
        public var deletedAnywayReason: String {
            switch self {
            case let .tooFewLines(lines, duration):
                return CaptureCheck.deletedAnywayReason(lines: lines, duration: duration)
            case let .silentChannel(stream, _, duration):
                return "\(Self.side(stream)) carried audio above the noise floor and "
                    + "\(CaptureCheck.silentChannelMark), which looks like a capture failure — "
                    + CaptureCheck.deletedAnywayTail(duration: duration)
            }
        }

        /// The one line the island and the Meetings tab show.
        public var uiNote: String {
            switch self {
            case .tooFewLines: return CaptureCheck.uiNote
            case .silentChannel: return CaptureCheck.silentChannelUiNote
            }
        }

        /// The same, for the case where the audio went anyway.
        public var deletedAnywayUiNote: String {
            switch self {
            case .tooFewLines: return CaptureCheck.deletedAnywayUiNote
            case .silentChannel: return CaptureCheck.silentChannelDeletedAnywayUiNote
            }
        }

        private static func side(_ s: MeetingRecorder.Stream) -> String {
            s == .mic ? "your microphone" : "the meeting audio"
        }

        private static func otherSide(_ s: MeetingRecorder.Stream) -> String {
            s == .mic ? "the meeting audio" : "your microphone"
        }
    }

    /// "115 MB", for a sentence a person has to weigh.
    public static func sizeLabel(_ duration: Double) -> String {
        let mb = max(0, duration) * bytesPerSecond / 1_000_000
        return mb < 1 ? "under 1 MB" : "about \(Int(mb.rounded())) MB"
    }

    private static func lineCount(_ lines: Int) -> String {
        "only \(lines) transcript line" + (lines == 1 ? "" : "s")
    }

    /// The `recordingsKeptReason` written into `meeting.json`, so a person
    /// (or the agent) reading the record later knows why the audio is
    /// still there when the setting says it should not be.
    public static func keptReason(lines: Int, duration: Double) -> String {
        "kept despite the delete-after-notes setting: \(lineCount(lines)) "
            + "from \(Timeline.clock(duration)) of recording, "
            + "which looks more like a capture failure than a quiet meeting"
    }

    /// The other half of the same honesty: the result did look like a
    /// capture failure, and the audio was deleted anyway because the
    /// meeting was past the ceiling. Somebody looking for the evidence
    /// later must find out that it is gone, and why, rather than assuming
    /// it was never kept.
    public static func deletedAnywayReason(lines: Int, duration: Double) -> String {
        "\(lineCount(lines)) from \(Timeline.clock(duration)) of recording, which looks like a "
            + "capture failure — " + deletedAnywayTail(duration: duration)
    }

    /// The half of that sentence both rules share: the size, and why it
    /// wins over the evidence.
    static func deletedAnywayTail(duration: Double) -> String {
        "but the recordings were deleted as your setting asks: at "
            + "\(Timeline.clock(duration)) they are \(sizeLabel(duration)), and keeping a recording "
            + "of other people that size against your own instruction is worse than losing the "
            + "evidence. Meetings under \(Int(keepCeilingSeconds / 60)) minutes are kept."
    }

    /// What the island and the Meetings tab say. Plain, and it names the
    /// suspicion rather than hiding it behind "Notes written."
    public static let uiNote =
        "Kept the audio — almost nothing was transcribed, so it may be a capture problem."

    /// The same, for the case where the audio went anyway.
    public static let deletedAnywayUiNote =
        "Almost nothing was transcribed, which may be a capture problem — the recordings were "
        + "deleted as your setting asks, because this meeting was too long to keep."

    /// The two the second rule says instead. "Almost nothing was
    /// transcribed" would be a lie here: the far end may have produced
    /// forty lines, and what is wrong is that one side produced none.
    public static let silentChannelUiNote =
        "Kept the audio — one side carried sound but nothing was transcribed from it, so it may "
        + "be a capture problem."

    public static let silentChannelDeletedAnywayUiNote =
        "One side carried sound but nothing was transcribed from it, which may be a capture "
        + "problem — the recordings were deleted as your setting asks, because this meeting was "
        + "too long to keep."

    /// The phrase every silent-channel sentence carries. `meeting.json`
    /// stores the reason, not which rule wrote it, so this is how a record
    /// read back later is matched to its short note.
    public static let silentChannelMark = "produced no transcript lines"

    /// Every short note, for a caller that has to strip them out of a
    /// status line.
    public static var allUiNotes: [String] {
        [uiNote, deletedAnywayUiNote, silentChannelUiNote, silentChannelDeletedAnywayUiNote]
    }

    /// The short note for a `recordingsKeptReason` / `recordingsDeletedNote`
    /// read back from a record.
    public static func shortNote(keptReason: String) -> String {
        keptReason.contains(silentChannelMark) ? silentChannelUiNote : uiNote
    }

    public static func shortNote(deletedNote: String) -> String {
        deletedNote.contains(silentChannelMark) ? silentChannelDeletedAnywayUiNote : deletedAnywayUiNote
    }
}

/// Turns a finished meeting into `summary.md` and `meeting.json`. When the
/// brain is unavailable or answers with nothing usable, the record says so
/// and only the transcript is written — never a made-up summary.
public enum MeetingSummary {

    public struct Outcome: Sendable {
        public var record: MeetingRecord
        public var summaryURL: URL?
        public var recordURL: URL
        /// One line for the island / status: "Notes written" or why not.
        public var message: String

        /// False when this outcome was computed but never reached disk: the
        /// meeting's record already had an owner (`RecordClaim`), because
        /// `finish` came back after the deadline had already been answered.
        public var wroteRecord: Bool

        /// Public so the app can build one without going through `write` —
        /// the transcript-only outcome when `finish` misses its deadline.
        public init(record: MeetingRecord, summaryURL: URL?, recordURL: URL, message: String,
                    wroteRecord: Bool = true) {
            self.record = record
            self.summaryURL = summaryURL
            self.recordURL = recordURL
            self.message = message
            self.wroteRecord = wroteRecord
        }
    }

    /// `summarise` false skips the brain entirely (the setting); nil brain
    /// means the same as unreachable.
    ///
    /// `levels` is what the meters saw of each stream, and it is what lets
    /// the keep-audio rule tell a dead channel from a webinar; nil means
    /// nobody measured, and the rule falls back to line density alone.
    ///
    /// `attendees` is the calendar invite (Phase B), `youName` the name Moe
    /// knows the user by. Both are empty on every path where the calendar
    /// says nothing — no event, no attendees, access not granted — and then
    /// `SpeakerNaming.match` returns a book with no names in it and every
    /// line below is byte for byte what it was before Phase B.
    public static func write(folder: URL, segments: [Segment], startedAt: Date, duration: Double,
                             drift: DriftReport, warnings: [String] = [],
                             bookmarks rawBookmarks: [Bookmark] = [], pauses: PauseLog = PauseLog(),
                             liveActions: [MeetingNotes.ActionItem] = [],
                             attendees: [MeetingAttendee] = [], youName: String? = nil,
                             captures: [CaptureRecord] = [], callApp: String? = nil,
                             brain: MeetingBrain?, summarise: Bool,
                             deleteRecordings: Bool = false,
                             levels: ChannelEvidence? = nil,
                             claim: RecordClaim? = nil) async -> Outcome {
        let speakers = Timeline.speakerNumbers(segments)
        let names = SpeakerNaming.match(clusters: speakers, attendees: attendees, youName: youName)
        // The named transcript is what the brain reads and what goes on
        // disk, so the notes come back talking about Dan rather than about
        // speaker 2 and the two never disagree.
        let transcript = Timeline.format(segments, names: names)
        let bookmarks = Bookmarks.labelled(rawBookmarks, in: segments)
        var record = MeetingRecord(startedAt: startedAt, durationSeconds: duration,
                                   folder: folder.path, speakers: speakers,
                                   driftNote: drift.note, bookmarks: bookmarks, offTheRecord: pauses.spans)
        record.attendees = attendees
        record.speakerNames = names.names
        record.captures = captures
        record.callApp = callApp
        // Decided here rather than beside the deletion at the bottom,
        // because `summary.md` is built on the way and the reason the audio
        // survived the delete setting belongs in the document the user
        // actually opens, not only in `meeting.json`.
        let suspicion = CaptureCheck.suspicion(segments: segments, duration: duration, levels: levels)
        let keepingAudio = deleteRecordings && suspicion != nil && duration <= CaptureCheck.keepCeilingSeconds
        var message: String
        // Held rather than written, so that every file this function
        // touches is written on the far side of the claim below: a `finish`
        // that came back too late must leave a `summary.md` the record
        // cannot mention as little as it may leave a record.
        var pendingSummary: (url: URL, markdown: String)?
        if segments.isEmpty {
            record.summaryFailure = "nothing was recognised on either stream"
            message = "Nothing was recognised — the transcript is empty."
        } else if !summarise {
            record.summaryFailure = "summarising is off in Settings › Meetings"
            message = "Transcript saved. Summarising is off, so no notes were written."
        } else if let brain {
            var extraWarnings: [String] = []
            let ask = NotesRequest(
                system: MeetingSummaryPrompt.system,
                user: MeetingSummaryPrompt.user(transcript: transcript, date: startedAt, duration: duration,
                                                bookmarks: bookmarks, captures: captures))
            do {
                let (reply, attempts) = try await ask.run(brain: brain)
                if attempts > 1 { extraWarnings.append("The notes took \(attempts) attempts to write.") }
                if var notes = MeetingNotes.parse(reply) {
                    // The minute-by-minute scan's items, confirmed by the
                    // full read: anything it saw that the summary missed is
                    // kept, duplicates are not.
                    notes.actionItems = ActionItemScan.merge(notes.actionItems, liveActions)
                    record.notes = notes
                    record.summarised = true
                    var footer = [drift.note, pauses.note] + warnings + extraWarnings
                    // The audio outlived the delete setting: say so where
                    // the notes are read. The same sentence goes into
                    // `meeting.json` for the Meetings pane.
                    if keepingAudio, let suspicion { footer.append("Audio " + suspicion.keptReason) }
                    footer.append("Transcript: transcript.txt in this folder. Notes written by your AI from the transcript; check anything that matters.")
                    pendingSummary = (folder.appendingPathComponent("summary.md"),
                                      notes.markdown(date: startedAt, duration: duration,
                                                     bookmarks: bookmarks, captures: captures, footer: footer))
                    message = "Notes written."
                } else {
                    // What actually came back, in the record. "the brain's
                    // reply was not notes" is what the 16:10 meeting on
                    // 2026-09-08 was left with, and it named nothing: not
                    // the reply, not how long it took (fifteen seconds for
                    // a 60 KB transcript, which is an error returning, not
                    // a model reading), not whether anything was retried.
                    // The gateway's own log had the answer — a claude-code
                    // session retired sixteen minutes earlier — and nothing
                    // in the meeting's record pointed at it.
                    record.summaryFailure = "the brain's reply was not notes: " + NotesRequest.excerpt(reply)
                    message = "Transcript saved. Your AI did not return usable notes."
                }
            } catch {
                record.summaryFailure = "brain unavailable: \(error.localizedDescription)"
                message = "Transcript saved. Your AI was not reachable, so there are no notes."
            }
        } else {
            record.summaryFailure = "brain unavailable"
            message = "Transcript saved. Your AI is not connected, so there are no notes."
        }

        let recordURL = folder.appendingPathComponent("meeting.json")

        // One owner for the record, from here down.
        //
        // When `finish` misses its deadline the app has already written a
        // record, told the user "Writing the notes took too long", listed
        // the meeting and kept the audio. This call is the one that missed
        // it, arriving with a summary request that was cancelled underneath
        // it — a strictly worse record — and it must not replace what the
        // user is looking at, nor delete recordings the fallback kept, nor
        // drop the `incomplete` flag. Nothing above this line has touched
        // the disk.
        guard claim?.claim() ?? true else {
            return Outcome(record: record, summaryURL: nil, recordURL: recordURL,
                           message: "The notes finished after the meeting had already been saved; "
                                  + "the record on disk is the one you were shown.",
                           wroteRecord: false)
        }

        // The transcript on disk was written by the live pass with numbered
        // labels; rewrite it only when there is a name to put in it, so a
        // meeting nobody could be named in never has its file touched here.
        if names.hasNames, !segments.isEmpty {
            let url = folder.appendingPathComponent(record.transcriptFile)
            try? (transcript + "\n").write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        if let pendingSummary {
            do {
                try pendingSummary.markdown.write(to: pendingSummary.url, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: pendingSummary.url.path)
                record.summaryFile = "summary.md"
            } catch {
                record.summaryFailure = "could not write summary.md: \(error.localizedDescription)"
                message = "Transcript saved, but the notes could not be written."
            }
        }

        // Deleting the audio is the privacy default and it is right for a
        // meeting that worked. It is exactly wrong for one that produced
        // almost no transcript: then the recording is the only evidence of
        // why, and the first real meeting deleted it — 95 seconds of
        // talking, one line, and nothing left to look at. Evidence has to
        // survive the case where it is needed most.
        //
        // `levels` is the second half of that: the rate rule cannot see a
        // meeting whose far end transcribed forty lines while the
        // microphone carried audio and produced none. Nil levels — an older
        // meeting, a crash, any path that never measured them — leave the
        // rate rule deciding on its own, exactly as before.
        if deleteRecordings, record.summarised {
            if keepingAudio, let suspicion {
                record.recordingsKeptReason = suspicion.keptReason
                message += " " + suspicion.uiNote
            } else {
                // Past the ceiling the setting wins — but not silently:
                // somebody who goes looking for the recording of a meeting
                // that plainly went wrong has to find out that it is gone
                // and why, rather than concluding the rule never fired.
                if let suspicion {
                    record.recordingsDeletedNote = suspicion.deletedAnywayReason
                    message += " " + suspicion.deletedAnywayUiNote
                }
                for name in ["system.wav", "mic.wav"] {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
                record.recordingsDeleted = true
            }
        }

        if let data = try? record.json() {
            try? data.write(to: recordURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        }
        return Outcome(record: record,
                       summaryURL: record.summaryFile.map { folder.appendingPathComponent($0) },
                       recordURL: recordURL, message: message)
    }
}
