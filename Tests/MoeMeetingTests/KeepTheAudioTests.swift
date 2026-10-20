import Foundation
import Testing
@testable import MoeMeeting

// MARK: - Keeping the evidence

struct CaptureCheckTests {

    /// The meeting that started this: 95 seconds, one transcript line, and
    /// then the audio deleted because the notes were written.
    @Test func theRealMeetingWouldHaveKeptItsAudio() {
        #expect(CaptureCheck.looksLikeCaptureFailure(lines: 1, duration: 95))
        #expect(CaptureCheck.keptReason(lines: 1, duration: 95).contains("only 1 transcript line"))
        #expect(CaptureCheck.keptReason(lines: 1, duration: 95).contains("01:35"))
        #expect(CaptureCheck.keptReason(lines: 2, duration: 95).contains("2 transcript lines"))
    }

    @Test func oneLinePerThirtySecondsIsTheBar() {
        #expect(!CaptureCheck.looksLikeCaptureFailure(lines: 1, duration: 30))   // exactly at the bar
        #expect(CaptureCheck.looksLikeCaptureFailure(lines: 1, duration: 31))
        #expect(!CaptureCheck.looksLikeCaptureFailure(lines: 2, duration: 60))
        #expect(!CaptureCheck.looksLikeCaptureFailure(lines: 120, duration: 3600))
        #expect(CaptureCheck.looksLikeCaptureFailure(lines: 119, duration: 3600))
    }

    /// The rule as applied has a ceiling: past it the delete setting wins.
    /// Both streams are 64 kB/s together, so half an hour is 115 MB and an
    /// hour is 230 MB — the point where "keep the evidence" turns into
    /// "ignore what the user asked for", with other people's voices.
    @Test func thereIsACeilingOnWhatWillBeKept() {
        #expect(CaptureCheck.keepCeilingSeconds == 1800)
        // Exactly at the ceiling: still kept.
        #expect(CaptureCheck.shouldKeepAudio(lines: 5, duration: 1800))
        // A second past it: it still looks like a capture failure, and the
        // audio goes anyway.
        #expect(CaptureCheck.looksLikeCaptureFailure(lines: 5, duration: 1801))
        #expect(!CaptureCheck.shouldKeepAudio(lines: 5, duration: 1801))
        // The three sizes from the review.
        #expect(CaptureCheck.sizeLabel(1800) == "about 115 MB")
        #expect(CaptureCheck.sizeLabel(3 * 3600) == "about 691 MB")
        #expect(CaptureCheck.sizeLabel(8 * 3600) == "about 1843 MB")
        // A dense long meeting is not a capture failure and never was.
        #expect(!CaptureCheck.shouldKeepAudio(lines: 400, duration: 3600))
    }

    @Test func aMeetingWithNoDurationIsNotJudged() {
        #expect(!CaptureCheck.looksLikeCaptureFailure(lines: 0, duration: 0))
        #expect(!CaptureCheck.looksLikeCaptureFailure(lines: 0, duration: -5))
    }
}

/// The rule where it actually bites: `MeetingSummary.write` with the
/// delete-after-notes setting on.
struct KeepTheAudioTests {

    private struct Notes: MeetingBrain {
        func complete(system: String, user: String) async throws -> String {
            #"{"title":"T","summary":"S","decisions":[],"action_items":[],"open_questions":[]}"#
        }
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["system.wav", "mic.wav"] {
            try Data("not really audio".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func lines(_ n: Int) -> [Segment] {
        (0..<n).map { Segment(start: Double($0), end: Double($0) + 0.5, speaker: .them(1), text: "line \($0)") }
    }

    @Test func aNormalMeetingStillHasItsAudioDeleted() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(folder: dir, segments: lines(40), startedAt: Date(), duration: 600,
                                             drift: DriftReport(systemSeconds: 600, micSeconds: 600, wallSeconds: 600),
                                             brain: Notes(), summarise: true, deleteRecordings: true)
        #expect(out.record.summarised)
        #expect(out.record.recordingsDeleted)
        #expect(out.record.recordingsKeptReason == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(out.message == "Notes written.")
    }

    /// One line from 95 seconds: the notes were written, so the old code
    /// deleted the only evidence of why there was one line.
    @Test func aSuspiciouslyEmptyMeetingKeepsItsAudioAndSaysWhy() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(folder: dir, segments: lines(1), startedAt: Date(), duration: 95,
                                             drift: DriftReport(systemSeconds: 95, micSeconds: 95, wallSeconds: 95),
                                             brain: Notes(), summarise: true, deleteRecordings: true)
        #expect(out.record.summarised)
        #expect(!out.record.recordingsDeleted)
        #expect(out.record.recordingsKeptReason?.contains("capture failure") == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.wav").path))
        // And the user is told, rather than just seeing "Notes written."
        #expect(out.message.contains(CaptureCheck.uiNote))
        // It survives the round trip through meeting.json.
        let reread = try MeetingRecord.load(dir.appendingPathComponent("meeting.json"))
        #expect(reread.recordingsKeptReason == out.record.recordingsKeptReason)
    }

    /// Three hours, two lines: plainly a capture failure, and 690 MB of
    /// other people held against an explicit "delete recordings". The
    /// setting wins — and the record says the evidence went and why, so
    /// nobody later mistakes it for the rule never having fired.
    @Test func aLongEmptyMeetingIsDeletedAsAskedAndSaysSo() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(folder: dir, segments: lines(2), startedAt: Date(), duration: 3 * 3600,
                                             drift: DriftReport(systemSeconds: 0, micSeconds: 0, wallSeconds: 0),
                                             brain: Notes(), summarise: true, deleteRecordings: true)
        #expect(out.record.recordingsDeleted)
        #expect(out.record.recordingsKeptReason == nil)
        #expect(out.record.recordingsDeletedNote?.contains("about 691 MB") == true)
        #expect(out.record.recordingsDeletedNote?.contains("30 minutes") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(out.message.contains(CaptureCheck.deletedAnywayUiNote))
        let reread = try MeetingRecord.load(dir.appendingPathComponent("meeting.json"))
        #expect(reread.recordingsDeletedNote == out.record.recordingsDeletedNote)
    }

    /// An ordinary meeting that simply had little said in it is deleted
    /// with nothing said about it — the note is only for the suspicious case.
    @Test func aNormalLongMeetingSaysNothingAboutItsAudio() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(folder: dir, segments: lines(400), startedAt: Date(), duration: 3600,
                                             drift: DriftReport(systemSeconds: 0, micSeconds: 0, wallSeconds: 0),
                                             brain: Notes(), summarise: true, deleteRecordings: true)
        #expect(out.record.recordingsDeleted)
        #expect(out.record.recordingsDeletedNote == nil)
        #expect(out.message == "Notes written.")
    }

    @Test func recordsWrittenBeforeTheFieldExistedStillLoad() throws {
        let json = #"{"startedAt":"2026-08-30T18:27:03Z","durationSeconds":95,"folder":"/tmp/x"}"#
        let record = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(record.recordingsKeptReason == nil)
        #expect(record.durationSeconds == 95)
    }
}

// MARK: - The one-sided case

/// A dead or misrouted channel and a webinar produce the same transcript —
/// one side full, the other empty — and the line-rate rule keeps neither,
/// because the full side clears the rate on its own. Only the levels
/// separate them.
struct SilentChannelTests {

    private func them(_ n: Int) -> [Segment] {
        (0..<n).map { Segment(start: Double($0), end: Double($0) + 0.5, speaker: .them(1), text: "line \($0)") }
    }

    private func bothSides(_ n: Int) -> [Segment] {
        (0..<n).map {
            Segment(start: Double($0), end: Double($0) + 0.5,
                    speaker: $0.isMultiple(of: 2) ? .you : .them(1), text: "line \($0)")
        }
    }

    /// Ten minutes of meeting: the bar is 30 s. Both streams carried
    /// minutes of audio, which is what a person who spoke produces.
    private let live = ChannelEvidence(micSoundSeconds: 180, systemSoundSeconds: 240)

    /// The case that started this: forty lines from the far end, none from
    /// the microphone, and the microphone was live the whole time. The rate
    /// rule sees a dense meeting and deletes the only evidence there is.
    @Test func aDeadMicrophoneKeepsItsAudio() {
        let meeting = them(40)
        #expect(!CaptureCheck.looksLikeCaptureFailure(lines: meeting.count, duration: 600))
        #expect(!CaptureCheck.shouldKeepAudio(lines: meeting.count, duration: 600))
        #expect(CaptureCheck.shouldKeepAudio(segments: meeting, duration: 600, levels: live))
        let why = CaptureCheck.suspicion(segments: meeting, duration: 600, levels: live)
        #expect(why == CaptureCheck.Suspicion.silentChannel(.mic, otherLines: 40, duration: 600))
        #expect(why?.keptReason.contains("your microphone") == true)
        #expect(why?.keptReason.contains("produced no transcript lines") == true)
        #expect(why?.uiNote == CaptureCheck.silentChannelUiNote)
    }

    /// The same transcript, and the audio must go: the microphone was
    /// genuinely silent because the user was listening.
    @Test func aWebinarHasItsAudioDeleted() {
        let listening = ChannelEvidence(micSoundSeconds: 0, systemSoundSeconds: 240)
        #expect(!CaptureCheck.shouldKeepAudio(segments: them(40), duration: 600, levels: listening))
        #expect(CaptureCheck.suspicion(segments: them(40), duration: 600, levels: listening) == nil)
    }

    /// The listener nobody had in mind: twenty minutes of webinar, and a
    /// microphone that crossed the floor for twenty-five seconds in total —
    /// typing notes, two coughs, a chair. Not one word was said, so nothing
    /// was lost and there is nothing to keep evidence of. A flat
    /// few-second bar keeps this, and the meeting is under the ceiling so
    /// nothing else stops it: 115 MB of somebody else's webinar held
    /// against an explicit delete setting.
    @Test func aListenerWhoTypedAndCoughedStillHasTheirAudioDeleted() {
        let typing = ChannelEvidence(micSoundSeconds: 25, systemSoundSeconds: 900)
        #expect(typing.micSoundSeconds > 3)                       // a flat 3 s bar would keep it
        #expect(1200 <= CaptureCheck.keepCeilingSeconds)          // and the ceiling would not
        #expect(!CaptureCheck.shouldKeepAudio(segments: them(80), duration: 1200, levels: typing))
        #expect(CaptureCheck.suspicion(segments: them(80), duration: 1200, levels: typing) == nil)
        // Somebody who actually spoke in the same meeting and was not
        // transcribed clears the bar — three minutes against sixty seconds.
        let spoke = ChannelEvidence(micSoundSeconds: 180, systemSoundSeconds: 900)
        #expect(CaptureCheck.shouldKeepAudio(segments: them(80), duration: 1200, levels: spoke))
    }

    /// And the mirror: the far end carried audio and transcribed nothing
    /// while the user talked — a tap on the wrong process, or a call app
    /// whose audio never reached it.
    @Test func aFarEndThatCarriedAudioAndTranscribedNothingIsKept() {
        let mine = (0..<40).map { Segment(start: Double($0), end: Double($0) + 0.5, speaker: .you, text: "x") }
        #expect(CaptureCheck.shouldKeepAudio(segments: mine, duration: 600, levels: live))
        #expect(CaptureCheck.suspicion(segments: mine, duration: 600, levels: live)
                == CaptureCheck.Suspicion.silentChannel(.system, otherLines: 40, duration: 600))
        // A call where nothing was played is not that: the far end was quiet.
        let quietCall = ChannelEvidence(micSoundSeconds: 180, systemSoundSeconds: 0)
        #expect(!CaptureCheck.shouldKeepAudio(segments: mine, duration: 600, levels: quietCall))
    }

    /// The test the reverted attempt broke, in its pure form: both sides
    /// spoke, so nothing is suspicious however loud the channels were.
    @Test func aNormalTwoSidedMeetingIsDeleted() {
        #expect(!CaptureCheck.shouldKeepAudio(segments: bothSides(40), duration: 600, levels: live))
        #expect(CaptureCheck.suspicion(segments: bothSides(40), duration: 600, levels: live) == nil)
    }

    /// No levels — an older meeting, a crash, a path that never measured
    /// them — must decide exactly as the line-rate rule alone always did.
    /// Absent evidence can never mean "keep".
    @Test func withoutLevelsTheRuleIsExactlyTheOldOne() {
        for (segments, duration) in [(them(40), 600.0), (them(1), 95.0), (them(0), 60.0),
                                     (them(2), 3 * 3600.0), (bothSides(400), 3600.0),
                                     (them(5), 1800.0), (them(5), 1801.0), (them(0), 0.0)] {
            #expect(CaptureCheck.shouldKeepAudio(segments: segments, duration: duration, levels: nil)
                    == CaptureCheck.shouldKeepAudio(lines: segments.count, duration: duration),
                    "\(segments.count) lines in \(duration) s")
        }
        // Including the one-sided shape itself: with nothing measured it is
        // deleted, as before.
        #expect(!CaptureCheck.shouldKeepAudio(segments: them(40), duration: 600, levels: nil))
    }

    /// The ceiling is about size, so it applies to both rules — and the
    /// record still says the evidence went and why.
    @Test func theCeilingAppliesToTheSilentChannelRuleToo() {
        // Three hours, and a microphone that carried an hour of audio
        // without producing a line — well over the 540 s bar.
        let loud = ChannelEvidence(micSoundSeconds: 3600, systemSoundSeconds: 3600)
        #expect(!CaptureCheck.shouldKeepAudio(segments: them(400), duration: 3 * 3600, levels: loud))
        let why = CaptureCheck.suspicion(segments: them(400), duration: 3 * 3600, levels: loud)
        #expect(why?.deletedAnywayReason.contains("about 691 MB") == true)
        #expect(why?.deletedAnywayReason.contains("30 minutes") == true)
        #expect(why?.deletedAnywayUiNote == CaptureCheck.silentChannelDeletedAnywayUiNote)
    }

    /// A record read back later carries the sentence, not the rule that
    /// wrote it, and the island's one-liner has to be recovered from it.
    @Test func theShortNoteIsRecoveredFromTheStoredReason() {
        let dead = CaptureCheck.suspicion(segments: them(40), duration: 600, levels: live)!
        let thin = CaptureCheck.suspicion(segments: them(1), duration: 95, levels: nil)!
        #expect(CaptureCheck.shortNote(keptReason: dead.keptReason) == CaptureCheck.silentChannelUiNote)
        #expect(CaptureCheck.shortNote(keptReason: thin.keptReason) == CaptureCheck.uiNote)
        #expect(CaptureCheck.shortNote(deletedNote: dead.deletedAnywayReason)
                == CaptureCheck.silentChannelDeletedAnywayUiNote)
        #expect(CaptureCheck.shortNote(deletedNote: thin.deletedAnywayReason) == CaptureCheck.deletedAnywayUiNote)
        #expect(CaptureCheck.allUiNotes.count == 4)
    }
}

/// Where the evidence comes from: what a running meeting already measures.
struct ChannelEvidenceTests {

    private func feed(_ h: inout ChannelHealth, micDb: Float, systemDb: Float, seconds: Double) {
        var t = 0.0
        while t <= seconds { h.observe(micDb: micDb, systemDb: systemDb, at: t); t += 0.1 }
    }

    /// The bar is a share of the meeting, so the same forty seconds are
    /// evidence in a five-minute call and nothing in a twenty-minute one.
    @Test func carriedAudioIsAShareOfTheMeeting() {
        var h = ChannelHealth()
        feed(&h, micDb: -30, systemDb: -70, seconds: 40)
        #expect(h.micSoundSeconds >= 39)
        #expect(h.systemSoundSeconds == 0)
        let evidence = ChannelEvidence(health: h)
        #expect(evidence.micCarriedAudio(over: 300))            // bar 15 s
        #expect(!evidence.micCarriedAudio(over: 20 * 60))       // bar 60 s
        #expect(!evidence.systemCarriedAudio(over: 300))
        // 5% of the meeting, with a 15 s floor under it for short ones.
        #expect(ChannelEvidence.carriedAudioSeconds(duration: 95) == 15)
        #expect(ChannelEvidence.carriedAudioSeconds(duration: 600) == 30)
        #expect(ChannelEvidence.carriedAudioSeconds(duration: 1800) == 90)
    }

    /// A cough in a webinar clears -50 dBFS for a moment and transcribes to
    /// nothing, quite correctly. Keeping the recording on that would be the
    /// rejected rule wearing a different hat.
    @Test func aBlipAboveTheFloorIsNotAudioCarried() {
        var h = ChannelHealth()
        feed(&h, micDb: -30, systemDb: -70, seconds: 0.8)
        #expect(h.lastMicSound != nil)          // the live status did notice it
        #expect(h.micSoundSeconds < ChannelEvidence.carriedAudioSeconds(duration: 95))
        #expect(!ChannelEvidence(health: h).micCarriedAudio(over: 95))
    }

    /// The quiet room that was captured correctly: -65 dBFS for the whole
    /// meeting, which is below the -50 dBFS floor the speech gate uses.
    @Test func aQuietRoomCarriedNothing() {
        var h = ChannelHealth()
        feed(&h, micDb: -65, systemDb: -200, seconds: 40)
        #expect(!ChannelEvidence(health: h).micCarriedAudio(over: 40))
        #expect(!ChannelEvidence(health: h).systemCarriedAudio(over: 40))
    }

    /// The misrouted case the meters cannot see: mic.wav is near-silent
    /// because it was written from the wrong channel of the bus, and the
    /// audio did arrive.
    @Test func audioOnAnotherChannelOfTheBusCountsAsCarried() {
        var h = ChannelHealth()
        feed(&h, micDb: -95, systemDb: -70, seconds: 40)
        let misrouted = ChannelReport.make(db: [-95, -30], chosen: 0)
        #expect(misrouted.warning != nil)
        #expect(ChannelEvidence(health: h, micChannels: misrouted).micCarriedAudio(over: 40))
        // A device delivering nothing on every channel is not that: there
        // is nothing in the recording to diagnose from.
        let dead = ChannelReport.make(db: [-200, -200], chosen: 0)
        #expect(dead.implausiblyQuiet)
        #expect(!ChannelEvidence(health: h, micChannels: dead).micCarriedAudio(over: 40))
    }

    @Test func aStalledClockCannotInflateTheSeconds() {
        var h = ChannelHealth()
        h.observe(micDb: -30, systemDb: -30, at: 0)
        h.observe(micDb: -30, systemDb: -30, at: 600)     // the machine slept
        #expect(h.micSoundSeconds == 1)
        #expect(!ChannelEvidence(health: h).micCarriedAudio(over: 600))
    }
}

/// The one-sided rule through `MeetingSummary.write`, where it decides what
/// is on the user's disk.
struct SilentChannelWriteTests {

    private struct Notes: MeetingBrain {
        func complete(system: String, user: String) async throws -> String {
            #"{"title":"T","summary":"S","decisions":[],"action_items":[],"open_questions":[]}"#
        }
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-dead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["system.wav", "mic.wav"] {
            try Data("not really audio".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func them(_ n: Int) -> [Segment] {
        (0..<n).map { Segment(start: Double($0), end: Double($0) + 0.5, speaker: .them(1), text: "line \($0)") }
    }

    private func write(_ dir: URL, segments: [Segment], levels: ChannelEvidence?) async -> MeetingSummary.Outcome {
        await MeetingSummary.write(folder: dir, segments: segments, startedAt: Date(), duration: 600,
                                   drift: DriftReport(systemSeconds: 600, micSeconds: 600, wallSeconds: 600),
                                   brain: Notes(), summarise: true, deleteRecordings: true, levels: levels)
    }

    @Test func aDeadMicrophoneKeepsItsAudioAndSaysWhy() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await write(dir, segments: them(40),
                              levels: ChannelEvidence(micSoundSeconds: 180, systemSoundSeconds: 240))
        #expect(out.record.summarised)
        #expect(!out.record.recordingsDeleted)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(out.record.recordingsKeptReason?.contains("your microphone") == true)
        #expect(out.message.contains(CaptureCheck.silentChannelUiNote))
        // Visible where the user reads the meeting, not only in meeting.json.
        let md = try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(md.contains("produced no transcript lines"))
        let reread = try MeetingRecord.load(dir.appendingPathComponent("meeting.json"))
        #expect(reread.recordingsKeptReason == out.record.recordingsKeptReason)
    }

    @Test func aWebinarHasItsAudioDeletedAndSaysNothing() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await write(dir, segments: them(40),
                              levels: ChannelEvidence(micSoundSeconds: 0, systemSoundSeconds: 240))
        #expect(out.record.recordingsDeleted)
        #expect(out.record.recordingsKeptReason == nil)
        #expect(out.record.recordingsDeletedNote == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
        #expect(out.message == "Notes written.")
        let md = try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(!md.contains("delete-after-notes"))
    }

    @Test func measuringNothingDeletesTheAudioJustAsBefore() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await write(dir, segments: them(40), levels: nil)
        #expect(out.record.recordingsDeleted)
        #expect(out.record.recordingsKeptReason == nil)
        #expect(out.message == "Notes written.")
    }
}
