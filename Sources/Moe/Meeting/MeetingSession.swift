import AppKit
import Foundation
import MoeMeeting

/// A meeting's requests to the brain, over the same
/// `POST /v1/chat/completions` the conversation and the dictation polisher
/// use, on sessions of their own so they never share a transcript with the
/// chat.
///
/// # Why there is more than one session
///
/// A meeting asks the brain five different things: action items every
/// minute, a recap when you come back, a caption for a screenshot, the
/// notes at the end, and — if it is switched on — a request to send those
/// notes to Telegram. All five used one `HermesMeetingBrain` with one
/// session id, which meant one conversation.
///
/// That is what broke the notes. The action scan runs about sixty times an
/// hour, and its whole prompt is *reply with `{"actions":[…]}` and nothing
/// else*. By the end of a long meeting the session has been told that sixty
/// times, and when the notes request arrives — a different prompt asking
/// for a six-key object — the model answers in the shape it has been
/// answering in all hour. `MeetingNotes.parse` rejects it, the record says
/// "the brain's reply was not notes", and an hour-long meeting has none.
///
/// Measured on 2026-09-08's 16:10 transcript, against this Mac's own
/// gateway, same prompt, same model:
///
///   * **on the meeting session** — 11.6 s, and the reply is
///     `{"actions":[{"who":…,"what":…,"when":…}]}`: the *scan's* format,
///     for a request that never mentioned actions;
///   * **on a fresh session** — 64.7 s, and the reply is the notes.
///
/// The eleven seconds are the tell, and they match the original failure
/// exactly: that meeting stopped at 21:12:30 and was recorded as having no
/// notes at 21:12:45. It was never a timeout or a dead child. The model was
/// answering the wrong question, quickly, because it had been asked that
/// question sixty times.
///
/// So each purpose gets its own session id. The notes get a **fresh** one
/// per request: the whole transcript is in the prompt, there is nothing to
/// carry over, and nothing may leak in.
final class HermesMeetingBrain: MeetingBrain, @unchecked Sendable {

    /// The five conversations and how their sessions are derived live in
    /// `MoeMeeting/MeetingBrainSessions.swift`, where they are testable.
    typealias Purpose = MeetingBrainPurpose

    private let endpoint: HermesEndpoint
    /// The model this purpose runs on: the provider's cheapest for the
    /// recurring jobs, the person's choice for the notes
    /// (`MeetingBrainPurpose.usesCheapestModel`).
    private let brain: BrainSelection
    /// The person's own choice, for when the cheap model is refused.
    private let chosen: BrainSelection
    private let session: URLSession
    private let purpose: Purpose
    /// Held only for the continuous purposes; nil means mint one per call.
    private let fixedSessionID: String?

    /// `meetingID` keeps one meeting's recurring sessions apart from the
    /// next meeting's, so an hour of last week's action items is not still
    /// in the conversation.
    init(config: Config, purpose: Purpose, meetingID: String) {
        endpoint = HermesEndpoint(config: config)
        chosen = BrainSelection(config: config)
        brain = purpose.usesCheapestModel ? .cheapest(config: config) : chosen
        self.purpose = purpose
        let cfg = HermesEndpoint.sessionConfiguration()
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 180
        session = URLSession(configuration: cfg)
        fixedSessionID = purpose.isContinuous
            ? MeetingBrainSession.id(meetingID: meetingID, purpose: purpose)
            : nil
    }

    private var sessionID: String { fixedSessionID ?? UUID().uuidString.lowercased() }

    func complete(system: String, user: String) async throws -> String {
        try await complete(system: system, user: user, image: nil)
    }

    /// The same request with a picture attached (a meeting screenshot to
    /// caption). `image` nil is exactly `complete(system:user:)`.
    func complete(system: String, user: String, image: ImageAttachment?) async throws -> String {
        let images = image.map { [$0] } ?? []
        var (data, status) = try await send(system: system, user: user, images: images, via: brain)
        // The cheap model is a table entry, not a promise the account serves
        // it (an API key without access to that model, a ChatGPT plan that
        // lists a different small one). A refusal costs one retry on the
        // person's own model, never the scan.
        if status != 200, brain != chosen {
            Log.write("meeting: \(purpose.rawValue) on \(brain.model) answered HTTP \(status); "
                      + "retrying on \(chosen.model)")
            (data, status) = try await send(system: system, user: user, images: images, via: chosen)
        }
        guard status == 200 else { throw MeetingSessionError("the brain answered HTTP \(status)") }
        guard let text = DictationPolisher.content(from: data) else {
            throw MeetingSessionError("the brain's reply was unreadable")
        }
        return text
    }

    private func send(system: String, user: String, images: [ImageAttachment],
                      via selection: BrainSelection) async throws -> (Data, Int) {
        let req = endpoint.chatRequest(sessionID: sessionID, sessionKey: purpose.sessionKey,
                                       system: system, user: user, stream: true, brain: selection,
                                       images: images,
                                       origin: nil)   // other people's words: never live
        let (data, response) = try await session.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct MeetingSessionError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ d: String) { description = d }
    var errorDescription: String? { description }
}

/// One meeting from start to notes: the recorder, the live transcriber on
/// a 30 s clock, the summary at the end. Owned by `Conductor`, which holds
/// the published state; this is the part that touches audio and files.
@MainActor
final class MeetingSession {

    let folder: URL
    let recorder: MeetingRecorder
    let transcriber: MeetingTranscriber
    private var ticker: Task<Void, Never>?
    private var levelTimer: Timer?
    /// Latest levels, for the Meetings pane.
    private(set) var systemDb: Float = -200
    private(set) var micDb: Float = -200
    /// The 15 s "levels mic -52 dBFS, system -∞" line. `ChannelHealth`
    /// answers a boolean and the first real meeting proved that is not
    /// enough to tell quiet speech from a dead device.
    private var levelLog = LevelLog()
    /// The per-channel line and the wrong-channel check are each logged
    /// once: the first after the canceller has settled, the second late
    /// enough that a pause between sentences cannot be mistaken for a dead
    /// channel. See `MicChannelWatch`.
    private var channelWatch = MicChannelWatch()
    /// The last per-channel report, kept because `recorder.stop()` releases
    /// the microphone and with it the measurement — and the keep-audio
    /// decision at the end of `finish` needs it *after* the stop.
    private var micChannels: ChannelReport?
    /// True once the tap has delivered a buffer. Stays false without the
    /// System Audio Recording grant — macOS delivers nothing rather than
    /// an error — or while the call app is silent.
    private(set) var tapDelivering = false
    /// "mic silent" / "no meeting audio" after 20 s of quiet on a channel.
    private(set) var health = ChannelHealth()
    private(set) var healthLine = ""
    /// Whether the call-audio stream is carrying anything at all, and what
    /// to do when it is not (`TapWatch`). Two of the three meetings on
    /// 2026-09-08 recorded an hour of digital silence on this stream and
    /// nothing in the app noticed.
    private var tapWatch = TapWatch()
    /// Nothing could bring the call audio back. The island says so; it
    /// stays set for the rest of the meeting.
    private(set) var tapIsDead = false
    /// Called once, when that happens.
    var onTapDead: (() -> Void)?
    private(set) var bookmarks: [Bookmark] = []
    /// Who the calendar said was invited, read once at start (Phase B).
    /// Empty when there is no event, no attendees, or no Calendar access —
    /// and then nothing downstream changes.
    var attendees: [MeetingAttendee] = []
    /// Screenshots and clips taken during the meeting (Phase D), handed
    /// over by `Conductor` before `finish` so they land in the record.
    var captures: [CaptureRecord] = []
    /// "Zoom", when the meeting was started from the call offer.
    var callApp: String?
    /// Who owns this meeting's `meeting.json`. Two things can write it —
    /// `finish` and, when `finish` misses its deadline,
    /// `transcriptOnlyOutcome` — and only the first of them may.
    let recordClaim = RecordClaim()
    var onTimeline: (([Segment]) -> Void)?
    /// The health line changed.
    var onHealth: ((String) -> Void)?

    init(base: URL, asr: MeetingAsr, diarizer: MeetingDiarizer?) throws {
        folder = try MeetingRecorder.makeFolder(base: base)
        recorder = MeetingRecorder(folder: folder)
        transcriber = MeetingTranscriber(folder: folder, asr: asr, diarizer: diarizer)
        transcriber.onUpdate = { [weak self] segments in
            Task { @MainActor in self?.onTimeline?(segments) }
        }
    }

    func start() throws {
        try recorder.start()
        Log.write("meeting: recording to \(folder.lastPathComponent)")
        // Which devices were actually opened. A meeting that hears nothing
        // is nearly always the wrong one — the default input having quietly
        // become a Continuity mic on a phone in another room, a headset
        // asleep — and until now nothing anywhere said which device this
        // was, so a near-silent recording could not be diagnosed at all.
        Log.write("meeting: mic \(recorder.micDescription)")
        Log.write("meeting: system tap on \(recorder.tapDescription)")
        let recorder = self.recorder
        let transcriber = self.transcriber
        ticker = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                // Two seconds, not five. The poll adds to the window's own
                // wait — a full window can sit finished for the rest of the
                // interval before anyone asks for it — so a 5 s poll on top
                // of a 30 s window was up to 35 s before a line appeared.
                // A tick with no full window does almost nothing: it compares
                // two frame counts and returns.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                await transcriber.tick(available: { recorder.frames($0) }, url: { recorder.url($0) })
                _ = self
            }
        }
        // Ten times a second, because the meters report the rms since the
        // last drain: draining once a second averages a 100 ms word into
        // 900 ms of silence and loses 10 dB of it.
        //
        // And one drainer only. Not because two would each see half the
        // audio — they would not; `LevelMeter.drain` accumulates and
        // resets, so every sample reaches exactly one drain and none is
        // lost — but because a second drainer makes the interval behind
        // every reading unpredictable. A "one second" reading becomes
        // whatever was left since the other timer's last 100 ms drain, and
        // an interval you cannot state is a level you cannot compare
        // against a floor or write in a log.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let l = self.recorder.levels()
                self.systemDb = l.systemDb
                self.micDb = l.micDb
                self.tapDelivering = self.recorder.tapIsDelivering
                let now = self.recorder.elapsed
                self.health.observe(micDb: l.micDb, systemDb: l.systemDb, at: now)
                if let levels = self.levelLog.observe(micDb: l.micDb, systemDb: l.systemDb, at: now) {
                    Log.write("meeting: \(levels)")
                }
                let channels = self.recorder.micChannelReport()
                if let channels { self.micChannels = channels }
                // A microphone that has gone quiet under a running engine
                // is rebuilt rather than reported: "mic silent" for an hour
                // is what this line used to be the only answer to.
                if let rebuilt = self.recorder.micWatchdog() {
                    Log.write("meeting: \(rebuilt)")
                }
                self.watchTheTap(at: now)
                for line in self.channelWatch.observe(channels, at: now) {
                    Log.write("meeting: mic \(line)")
                }
                let line = self.health.status(at: now, paused: self.recorder.isPaused)
                if line != self.healthLine {
                    self.healthLine = line
                    if !line.isEmpty { Log.write("meeting: \(line) at \(Timeline.clock(now))") }
                    self.onHealth?(line)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    /// Is the call-audio stream carrying anything, and if not, repair it.
    ///
    /// Called from the level timer, but only once a second: the two facts
    /// it needs are the sink's cumulative sound flag (free) and Core
    /// Audio's process list (cached at 1.2 s by `ProcessList.Signals`, and
    /// there is no point asking faster than it refreshes).
    ///
    /// Off the record the whole question is meaningless — both sinks are
    /// writing deliberate silence — so the clock is not fed at all.
    private func watchTheTap(at now: Double) {
        guard !recorder.isPaused, now - lastTapCheck >= 1 else { return }
        lastTapCheck = now
        let action = tapWatch.observe(
            // "Has not sounded for twenty seconds" is enough to try the
            // repairs; "has never carried a value at all" is what may
            // interrupt the person. See TapWatch — the two grades are the
            // difference between the 10:20 meeting (1.2 s of sound in
            // 2,126) and the 16:10 one (59 million exact zeros).
            systemQuiet: health.systemSilent(at: now),
            systemEverSounded: recorder.systemHasSound,
            somethingIsPlaying: OutputActivity.othersPlaying(),
            echoCancelling: recorder.isEchoCancelling,
            // Nothing has been said into the microphone yet, so there is
            // nothing to be misattributed and nothing worth interrupting
            // for. Five seconds of it, so a chair scraping is not speech.
            micHasSpeech: health.micSoundSeconds >= 5,
            at: now)
        switch action {
        case .none:
            return
        case .dropEchoCancellation:
            if let line = recorder.dropEchoCancellation() {
                Log.write("meeting: no call audio at \(Timeline.clock(now)) — \(line)")
            }
        case .rebuildTap:
            Log.write("meeting: no call audio at \(Timeline.clock(now)) — \(recorder.rebuildTap())")
        case .reportDead:
            tapIsDead = true
            Log.write("meeting: call audio never arrived (echo cancellation dropped, tap rebuilt "
                      + "\(tapWatch.rebuildCount)×) — telling the user at \(Timeline.clock(now))")
            onTapDead?()
        }
    }

    private var lastTapCheck: Double = -1

    var elapsed: Double { recorder.elapsed }
    var isPaused: Bool { recorder.isPaused }

    /// "Note this": a timestamp; the label comes from the transcript at the end.
    func addBookmark() {
        let t = recorder.elapsed
        bookmarks.append(Bookmark(time: t))
        Log.write("meeting: bookmark at \(Timeline.clock(t))")
    }

    /// Off the record. Nothing of the stretch is kept — silence goes to
    /// disk, the recogniser sees nothing, the record notes the gap.
    func setPaused(_ paused: Bool) {
        if paused { recorder.pause() } else { recorder.resume() }
        Log.write("meeting: \(paused ? "off the record" : "back on the record") at \(Timeline.clock(recorder.elapsed))")
    }

    /// Stop capture, finish the transcript, write the notes.
    func finish(brain: MeetingBrain?, summarise: Bool, deleteRecordings: Bool,
                liveActions: [MeetingNotes.ActionItem] = []) async -> MeetingSummary.Outcome {
        let claim = recordClaim
        ticker?.cancel(); ticker = nil
        levelTimer?.invalidate(); levelTimer = nil
        // Before the stop: it releases the microphone, and the per-channel
        // measurement goes with it.
        if let channels = recorder.micChannelReport() { micChannels = channels }
        recorder.stop()
        let drift = recorder.drift
        Log.write("meeting: stopped after \(Timeline.clock(recorder.elapsed)); "
                  + "system \(recorder.frames(.system)) frames, mic \(recorder.frames(.mic)) frames"
                  + (drift.isNoteworthy ? "; \(drift.note)" : ""))
        // What the meters saw of each stream over the whole meeting.
        // Logged because the bar it is judged against — a twentieth of the
        // meeting — is reasoned rather than measured: the one call where
        // somebody sits silent and types settles it, and this line is where
        // that answer is read off.
        let evidence = ChannelEvidence(health: health, micChannels: micChannels)
        Log.write("meeting: \(evidence.line(duration: recorder.elapsed))")
        let recorder = self.recorder
        let pauses = recorder.pauses
        let segments = await transcriber.finish(available: { recorder.frames($0) }, url: { recorder.url($0) },
                                                pauses: pauses)
        let outcome = await MeetingSummary.write(
            folder: folder, segments: segments, startedAt: recorder.epoch, duration: recorder.elapsed,
            drift: drift, warnings: transcriber.warnings, bookmarks: bookmarks, pauses: pauses,
            liveActions: liveActions, attendees: attendees, youName: Self.ownerName(),
            captures: captures, callApp: callApp,
            brain: brain, summarise: summarise, deleteRecordings: deleteRecordings,
            // Without this the keep-audio rule cannot tell a microphone
            // that carried audio and transcribed nothing — evidence, keep
            // it — from a webinar the user listened to in silence, where
            // the recording is other people's voices held against the
            // setting that promised to delete them.
            levels: evidence,
            claim: claim)
        guard outcome.wroteRecord else {
            Log.write("meeting: finish came back after the deadline had been answered; "
                      + "nothing written, the record on disk stands")
            return outcome
        }
        Log.write("meeting: \(outcome.message) (\(segments.count) lines, speakers \(outcome.record.speakers))")
        let named = outcome.record.speakerNames.compactMap(\.name)
        if !named.isEmpty { Log.write("meeting: named from the invite — \(named.joined(separator: ", "))") }
        return outcome
    }

    /// How long `finish` gets before the app stops waiting for it.
    ///
    /// Nothing inside it has a timeout of its own except the summary
    /// request: loading the speech model, recognising the tail and
    /// diarizing the whole system stream do not. If one of them never
    /// returns, the meeting parks at `.stopping` and the panel says
    /// "Writing your notes…" for as long as the app runs, with no way out
    /// and no notes.
    ///
    /// It has to scale with the recording, because diarization's cost is
    /// proportional to it; the arithmetic and the reasoning are in
    /// `MeetingFinishBudget`, where they can be tested.
    static func finishDeadline(recorded duration: Double) -> Double {
        MeetingFinishBudget.seconds(recorded: duration)
    }

    /// What the meeting becomes when `finish` misses that deadline: the
    /// transcript the live pass already wrote, and a record that says why
    /// there are no notes. The audio is deliberately not deleted.
    ///
    /// This record is the meeting's, and it stays. `Deadline.run` stops
    /// waiting for `finish`; it cannot stop it, so `finish` may still write
    /// afterwards — and it used to, over the top of this, leaving the panel
    /// saying "Writing the notes took too long" while a different record
    /// sat on disk with `incomplete` gone and the audio deleted. The late
    /// record is also the worse one: its summary request was cancelled with
    /// the task, so it says "brain unavailable" where this one says the
    /// truth about what happened. `recordClaim` gives the file one owner
    /// (see `RecordClaim`); the writes below are behind it.
    func transcriptOnlyOutcome(reason: String) -> MeetingSummary.Outcome {
        ticker?.cancel(); ticker = nil
        levelTimer?.invalidate(); levelTimer = nil
        recorder.stop()
        let segments = transcriber.timeline
        var record = MeetingRecord(startedAt: recorder.epoch, durationSeconds: recorder.elapsed,
                                   folder: folder.path, speakers: Timeline.speakerNumbers(segments),
                                   driftNote: recorder.drift.note, summaryFailure: reason,
                                   bookmarks: Bookmarks.labelled(bookmarks, in: segments),
                                   offTheRecord: recorder.pauses.spans)
        record.captures = captures
        record.callApp = callApp
        record.incomplete = true
        let url = folder.appendingPathComponent("meeting.json")
        // The other ordering: `finish` wrote in the moments before the box
        // settled, so its record — complete, with its notes — is already
        // there. Then this one is the worse of the two and the honest thing
        // is to show what is on disk rather than replace it and report a
        // failure the user does not have.
        guard recordClaim.claim() else {
            let existing = (try? MeetingRecord.load(url)) ?? record
            Log.write("meeting: finish finished as the deadline fired; its record stands")
            return MeetingSummary.Outcome(
                record: existing,
                summaryURL: existing.summaryFile.map { folder.appendingPathComponent($0) },
                recordURL: url,
                message: existing.summarised ? "Notes written." : "Transcript saved.")
        }
        if let data = try? record.json() {
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        Log.write("meeting: \(reason) — transcript kept (\(segments.count) lines), audio kept")
        return MeetingSummary.Outcome(record: record, summaryURL: nil, recordURL: url,
                                      message: "Transcript saved. Writing the notes took too long, so there are none.")
    }

    /// The app is quitting mid-meeting: close the WAVs (headers patched, so
    /// they play), keep what the live pass already wrote to transcript.txt,
    /// and leave a `meeting.json` that says the meeting is incomplete — so
    /// the Meetings pane lists it and nothing looks like finished notes.
    func abandon() {
        ticker?.cancel(); ticker = nil
        levelTimer?.invalidate(); levelTimer = nil
        let wasRecording = recorder.isRecording
        recorder.stop()
        guard wasRecording else { return }
        var record = MeetingRecord(startedAt: recorder.epoch, durationSeconds: recorder.elapsed, folder: folder.path,
                                   summaryFailure: "Moe quit while the meeting was being recorded",
                                   bookmarks: bookmarks, offTheRecord: recorder.pauses.spans)
        record.incomplete = true
        let url = folder.appendingPathComponent("meeting.json")
        // The same one-owner rule, for completeness: quitting mid-meeting
        // means `finish` never ran, so this always wins — but the file has
        // one writer either way.
        guard recordClaim.claim() else {
            Log.write("meeting: abandoned, but the record already had an owner; left as it is")
            return
        }
        if let data = try? record.json() {
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        Log.write("meeting: abandoned after \(Timeline.clock(recorder.elapsed)) (incomplete)")
    }

    // MARK: - Whose assistant

    /// The user's first name from Hermes's USER.md (`$HERMES_HOME` or
    /// ~/.hermes), for "<Name>'s assistant is taking notes". Read, never
    /// written: memory files are Hermes's.
    static func ownerName() -> String? {
        let url = hermesHome().appendingPathComponent("memories/USER.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MeetingOwner.name(fromUserMD: text)
    }

    /// `telegram:<own id>` when Hermes has a Telegram bot and an allowed
    /// user (its `.env`), else nil. Read only.
    static func telegramSelfTarget() -> String? {
        let url = hermesHome().appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return TelegramSelf.target(envText: text)
    }

    static func hermesHome() -> URL {
        ProcessInfo.processInfo.environment["HERMES_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
    }

    // MARK: - Permission

    /// System Settings › Privacy & Security › Screen & System Audio
    /// Recording. The grant is "System Audio Recording Only"; the pane is
    /// shared with Screen Recording.
    static let audioCaptureSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func openAudioCaptureSettings() {
        NSWorkspace.shared.open(audioCaptureSettingsURL)
    }
}
