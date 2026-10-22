import AVFoundation
import Foundation
import Testing
@testable import MoeMeeting

// Phase A2 — the meeting experience's pure parts (MeetingLive.swift and
// the repeat intent). See MEETING-MODE.md "Phase A2 — experience".

private func seg(_ start: Double, _ who: Speaker, _ text: String, len: Double = 2) -> Segment {
    Segment(start: start, end: start + len, speaker: who, text: text)
}

struct RepeatIntentTests {
    @Test(arguments: [
        "What did they just say?", "what did he say", "What did she just say",
        "repeat that", "Say that again.", "Hey Alfie, what did they say?",
        "sorry, what was that", "what did I miss",
    ])
    func repeatPhrasesMatch(_ s: String) {
        #expect(MeetingIntent.match(s) == .repeatLast)
    }

    @Test(arguments: [
        "what did they say about the budget", "repeat that to Dan", "what did he mean",
        "say that again slowly please", "what did they decide", "can you repeat the plan",
        "what's the time", "",
    ])
    func nearMissesDoNotMatch(_ s: String) {
        #expect(MeetingIntent.match(s) != .repeatLast)
    }

    @Test func startAndStopStillMatch() {
        #expect(MeetingIntent.match("start a meeting") == .start)
        #expect(MeetingIntent.match("stop recording") == .stop)
    }
}

struct TranscriptRecallTests {
    let lines = [seg(0, .them(1), "We ship Tuesday."), seg(5, .you, "Fine by me."), seg(9, .them(2), "I will send the notes.")]

    @Test func lastThemSegmentIsQuoted() {
        let a = TranscriptRecall.answer(lines, now: 12)
        #expect(a.contains("I will send the notes."))
        #expect(a.contains("00:09"))
        #expect(!a.contains("Fine by me"))
    }

    @Test func onlyYouSoFarFallsBackToTheLastTwentySeconds() {
        let you = [seg(0, .you, "Hello?"), seg(30, .you, "Can you hear me?")]
        let a = TranscriptRecall.answer(you, now: 40)
        #expect(a.hasPrefix("Last 20 s:"))
        #expect(a.contains("Can you hear me?") && !a.contains("Hello?"))
        #expect(TranscriptRecall.answer(you, now: 90).contains("Nothing from them yet"))
        let recent = TranscriptRecall.answer([], now: 40)
        #expect(recent == "Nothing has been transcribed yet.")
    }

    @Test func tailKeepsTheNewestForty() {
        let many = (0..<50).map { seg(Double($0), .them(1), "line \($0)") }
        let tail = TranscriptTail.tail(many)
        #expect(tail.count == 40)
        #expect(tail.first?.text == "line 10")
        #expect(tail.last?.text == "line 49")
        #expect(TranscriptTail.context(many).split(separator: "\n").count == 40)
        #expect(TranscriptTail.tail([], max: 40).isEmpty)
    }
}

struct ActionItemScanTests {
    @Test func parsesObjectsAndStrings() {
        let items = ActionItemScan.parse(#"{"actions":[{"who":"Dan","what":"send the deck","when":"Friday"},"book the room"]}"#)
        #expect(items.count == 2)
        #expect(items[0] == MeetingNotes.ActionItem(who: "Dan", what: "send the deck", when: "Friday"))
        #expect(items[1].what == "book the room")
        #expect(items[1].who.isEmpty)
    }

    @Test func emptyObjectAndJunkGiveNothing() {
        #expect(ActionItemScan.parse("{}").isEmpty)
        #expect(ActionItemScan.parse("nothing new here").isEmpty)
        #expect(ActionItemScan.parse(#"{"actions":[{"who":"Dan"}]}"#).isEmpty)   // no "what"
        #expect(ActionItemScan.parse(#"{"actions":"x"}"#).isEmpty)
    }

    @Test func fencedReplyIsAccepted() {
        let items = ActionItemScan.parse("```json\n{\"actions\":[{\"what\":\"call the vendor\"}]}\n```")
        #expect(items.map(\.what) == ["call the vendor"])
    }

    @Test func mergeDedupesOnTheTaskIgnoringCaseAndPunctuation() {
        let existing = [MeetingNotes.ActionItem(who: "them (speaker 2)", what: "send the notes", when: "after the call")]
        let live = [MeetingNotes.ActionItem(who: "Dan", what: "Send the notes.", when: ""),
                    MeetingNotes.ActionItem(who: "you", what: "book the follow-up", when: "Friday"),
                    MeetingNotes.ActionItem(who: "you", what: "Book the follow-up", when: "")]
        let merged = ActionItemScan.merge(existing, live)
        #expect(merged.map(\.what) == ["send the notes", "book the follow-up"])
        #expect(merged[0].who == "them (speaker 2)")   // the summary's version wins
    }

    @Test func mergeWithNothingExistingKeepsOrder() {
        let live = [MeetingNotes.ActionItem(who: "", what: "call Bob", when: ""), MeetingNotes.ActionItem(who: "", what: "email Ann", when: "")]
        #expect(ActionItemScan.merge([], live).map(\.what) == ["call Bob", "email Ann"])
        #expect(ActionItemScan.merge(live, []).map(\.what) == ["call Bob", "email Ann"])
        // Filler-only tasks have no key and are dropped rather than duplicated.
        #expect(ActionItemScan.merge([], [MeetingNotes.ActionItem(who: "", what: "the", when: "")]).isEmpty)
    }

    /// The pairs that actually shipped duplicated in a real summary.md: the
    /// full-transcript pass and the live scan named the same commitment in
    /// different words, and the old exact-key merge kept both.
    @Test func mergeCollapsesTheSameTaskWordedDifferently() {
        func pair(_ who: String, _ a: String, _ b: String) -> [MeetingNotes.ActionItem] {
            ActionItemScan.merge([MeetingNotes.ActionItem(who: who, what: a, when: "")],
                                 [MeetingNotes.ActionItem(who: who, what: b, when: "")])
        }
        #expect(pair("them", "Create a new Telegram bot and share the bot API key",
                             "Create a new bot on Telegram and share the bot API key").count == 1)
        #expect(pair("them", "Get familiar with the aid/aid-venza workspace setup",
                             "Get familiar with the aidvenza workspace setup").count == 1)
        #expect(pair("them", "Check what's new in open claw 2.0, including the multiplayer concept",
                             "Check what's new in the 2.0 release, including the multiplayer concept").count == 1)
        #expect(pair("you", "Send the link to the enterprise open claw deployment company found online",
                            "Send the link to the company/tool they found").count == 1)
    }

    /// The other half of the bar: two commitments that merely rhyme stay two.
    @Test func mergeKeepsTasksThatOnlyLookAlike() {
        func pair(_ a: String, _ b: String) -> Int {
            ActionItemScan.merge([MeetingNotes.ActionItem(who: "you", what: a, when: "")],
                                 [MeetingNotes.ActionItem(who: "you", what: b, when: "")]).count
        }
        #expect(pair("send the deck", "send the notes") == 2)
        #expect(pair("email Ann", "email Bob") == 2)
        #expect(pair("Send the instinct.co waitlist skip-the-line link",
                     "Send the link to the enterprise open claw deployment company") == 2)
        #expect(pair("Look into whether workflow blocks are available and check what open flow offers",
                     "Look into adding an audit trail for compliance") == 2)
    }

    /// Within the full read, "you" against somebody else is still two
    /// commitments: that pass had the whole transcript, and collapsing them
    /// would lose one person's work. Any other pair of labels may be one
    /// person twice — "Dan" is who "them (speaker 2)" turned out to be —
    /// and must still merge.
    @Test func theFullReadStillSplitsYouFromEveryoneElse() {
        let mine = MeetingNotes.ActionItem(who: "you", what: "check out what multiplayer means in open claw", when: "")
        let theirs = MeetingNotes.ActionItem(who: "them", what: "check what is new in open claw, including multiplayer", when: "")
        #expect(ActionItemScan.merge([mine, theirs], []).count == 2)

        let numbered = MeetingNotes.ActionItem(who: "them (speaker 2)", what: "send the notes round", when: "")
        let named = MeetingNotes.ActionItem(who: "Dan", what: "send round the notes", when: "")
        #expect(ActionItemScan.merge([numbered], [named]).count == 1)
    }

    /// A live-scan item is not evidence of a second commitment. It was
    /// written from sixty seconds of transcript whose speaker labels are
    /// provisional, so when the full read already covers the task it goes —
    /// whoever it named — and the full read's owner is what survives.
    ///
    /// Both pairs are verbatim from the 14:00 meeting on 2026-09-08, which
    /// shipped 33 action items where nine were distinct.
    @Test func aLiveScanItemNeverSurvivesTheFullReadOnAnOwnerDisagreement() {
        let full = MeetingNotes.ActionItem(who: "Ryan", what: "Check what level of 3CX access ISTA currently has", when: "")
        let live = MeetingNotes.ActionItem(who: "you", what: "Check with someone what level of 3CX access they have", when: "")
        let merged = ActionItemScan.merge([full], [live])
        #expect(merged.count == 1)
        #expect(merged.first?.who == "Ryan")

        let full2 = MeetingNotes.ActionItem(who: "Louie", what: "Pull historical call volume data from last year", when: "")
        let live2 = MeetingNotes.ActionItem(who: "you", what: "Pull historical call volume data from last year for the client", when: "")
        let merged2 = ActionItemScan.merge([full2], [live2])
        #expect(merged2.count == 1)
        #expect(merged2.first?.who == "Louie")
    }

    /// Two live-scan items a minute apart are both guesses, so neither may
    /// keep the other alive on an owner disagreement either.
    @Test func twoLiveScanItemsAlsoCollapse() {
        let a = MeetingNotes.ActionItem(who: "you", what: "send the deck to the client", when: "")
        let b = MeetingNotes.ActionItem(who: "them", what: "send the client the deck", when: "")
        #expect(ActionItemScan.merge([], [a, b]).count == 1)
    }

    /// The prompts say it in words too, because the merge can only tidy up
    /// after the model — it cannot invent the right owner, and it cannot
    /// tell that "restart the meeting recording" was never a task at all.
    @Test func bothPromptsRuleOutTalkAboutTheRecordingItself() {
        #expect(ActionItemScan.system.contains(MeetingChatter.rule))
        #expect(MeetingSummaryPrompt.system.contains(MeetingChatter.rule))
        #expect(MeetingChatter.rule.lowercased().contains("recording"))
    }

    /// The full-transcript pass can repeat itself too, so `existing` goes
    /// through the same sieve rather than being trusted wholesale.
    @Test func mergeDedupesWithinTheSummarysOwnList() {
        let existing = [MeetingNotes.ActionItem(who: "them", what: "Create a new Telegram bot and share the bot API key", when: ""),
                        MeetingNotes.ActionItem(who: "them", what: "Create a new bot on Telegram and share the bot API key", when: "")]
        #expect(ActionItemScan.merge(existing, []).count == 1)
    }

    @Test func promptFencesTheNewLines() {
        let u = ActionItemScan.user(newLines: "[00:01] them: do it")
        #expect(u.hasPrefix("<new-lines>"))
        #expect(u.contains("[00:01] them: do it"))
        #expect(ActionItemScan.system.contains(#"{"actions""#))
    }

    @Test func liveCursorHandsOutOnlyFreshLines() {
        var c = LiveCursor()
        let a = [seg(0, .them(1), "one"), seg(2, .them(1), "two")]
        #expect(c.take(a).map(\.text) == ["one", "two"])
        #expect(c.take(a).isEmpty)
        #expect(c.take(a + [seg(4, .you, "three")]).map(\.text) == ["three"])
        // A rewrite shorter than what was sent restarts from the front.
        #expect(c.take([seg(0, .them(1), "merged")]).map(\.text) == ["merged"])
    }
}

struct CatchUpTests {
    @Test func idleBeyondThresholdThenInputYieldsTheMissedSpan() {
        var c = CatchUp(threshold: 180)
        #expect(c.observe(idleSeconds: 10, at: 100) == nil)
        #expect(!c.isAway)
        #expect(c.observe(idleSeconds: 181, at: 400) == nil)   // away since 219
        #expect(c.isAway)
        #expect(c.observe(idleSeconds: 240, at: 460) == nil)   // still away
        let span = c.observe(idleSeconds: 0.5, at: 470)
        #expect(span == CatchUp.Span(start: 219, end: 470))
        #expect(!c.isAway)
    }

    @Test func shortAbsenceIsNotWorthARecap() {
        var c = CatchUp(threshold: 180)
        #expect(c.observe(idleSeconds: 100, at: 100) == nil)
        #expect(c.observe(idleSeconds: 0, at: 101) == nil)
    }

    @Test func lockMarksAwayAtOnceAndUnlockNeedsInputToFinish() {
        var c = CatchUp(threshold: 180)
        c.lock(at: 50)
        #expect(c.isAway)
        #expect(c.observe(idleSeconds: 0, at: 60) == nil)      // still locked: no span
        c.unlock()
        #expect(c.observe(idleSeconds: 30, at: 300) == nil)    // back, but no input yet
        #expect(c.observe(idleSeconds: 1, at: 301) == CatchUp.Span(start: 50, end: 301))
    }

    @Test func lockWhileAlreadyIdleKeepsTheEarlierStart() {
        var c = CatchUp(threshold: 60)
        _ = c.observe(idleSeconds: 70, at: 100)   // away since 30
        c.lock(at: 150)
        c.unlock()
        #expect(c.observe(idleSeconds: 0, at: 400) == CatchUp.Span(start: 30, end: 400))
    }

    @Test func missedLinesOverlapTheSpan() {
        let lines = [seg(0, .them(1), "before"), seg(99, .them(1), "straddles", len: 3),
                     seg(150, .you, "inside"), seg(210, .them(2), "after")]
        let missed = CatchUp.missed(lines, in: CatchUp.Span(start: 100, end: 200))
        #expect(missed.map(\.text) == ["straddles", "inside"])
        let u = CatchUp.user(missed: missed, span: CatchUp.Span(start: 100, end: 200))
        #expect(u.contains("01:40 to 03:20"))
        #expect(CatchUp.system.contains("two sentences"))
    }
}

struct NameMentionTests {
    @Test func wordBoundariesAndCase() {
        #expect(NameMention.matches(name: "Dan", in: "Let's ask Dan about it"))
        #expect(NameMention.matches(name: "Dan", in: "dan, are you there?"))
        #expect(NameMention.matches(name: "Dan", in: "That's Dan's call"))
        #expect(!NameMention.matches(name: "Dan", in: "The Danish office and Jordan"))
        #expect(!NameMention.matches(name: "Dan", in: "Daniel will do it"))
        #expect(!NameMention.matches(name: "Al", in: "Alright, all good"))
    }

    @Test func tooShortOrEmptyNamesNeverMatch() {
        #expect(!NameMention.matches(name: "", in: "anything"))
        #expect(!NameMention.matches(name: "J", in: "J is here"))
    }

    @Test func specialCharactersAreLiteral() {
        #expect(NameMention.matches(name: "O'Brien", in: "Ask O'Brien please"))
        #expect(!NameMention.matches(name: "A.B", in: "AxB"))
    }

    @Test func sentenceAndThemOnlyMentions() {
        #expect(NameMention.sentence(name: "Jordy", in: "First point. Jordy, can you take that? Thanks.") == "Jordy, can you take that")
        let lines = [seg(0, .you, "Jordy here"), seg(2, .them(1), "Jordy can take that"), seg(4, .them(2), "Sure")]
        #expect(NameMention.mentions(name: "Jordy", in: lines, from: 0).map(\.start) == [2])
        #expect(NameMention.mentions(name: "Jordy", in: lines, from: 2).isEmpty)
        #expect(NameMention.mentions(name: "Jordy", in: lines, from: 9).isEmpty)
    }
}

struct LiveActionsIntoSummaryTests {
    struct Canned: MeetingBrain {
        let reply: String
        func complete(system: String, user: String) async throws -> String { reply }
    }

    @Test func summaryConfirmsAndDedupesTheLiveItems() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = #"{"title":"T","summary":"S","action_items":[{"who":"them (speaker 2)","what":"send the notes","when":"after"}]}"#
        let live = [MeetingNotes.ActionItem(who: "Dan", what: "Send the notes", when: ""),
                    MeetingNotes.ActionItem(who: "you", what: "book the follow-up", when: "Friday")]
        let out = await MeetingSummary.write(folder: dir, segments: [seg(0, .them(1), "hi")], startedAt: Date(), duration: 5,
                                             drift: DriftReport(systemFrames: 80_000, micFrames: 80_000, wallSeconds: 5),
                                             liveActions: live, brain: Canned(reply: reply), summarise: true)
        #expect(out.record.notes?.actionItems.map(\.what) == ["send the notes", "book the follow-up"])
        let md = try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(md.contains("**you**: book the follow-up — by Friday"))
        #expect(md.components(separatedBy: "send the notes").count == 2)
    }

    @Test func remindedFlagRoundTripsAndIsAbsentByDefault() throws {
        var item = MeetingNotes.ActionItem(who: "you", what: "x", when: "")
        let bare = try String(data: JSONEncoder().encode(item), encoding: .utf8) ?? ""
        #expect(!bare.contains("reminded"))
        item.reminded = true
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(MeetingNotes.ActionItem.self, from: data).reminded == true)
    }
}

struct TelegramSelfTests {
    @Test func firstAllowedUserWithATokenIsTheTarget() {
        let env = "API_SERVER_KEY=x\nexport TELEGRAM_BOT_TOKEN=\"123:abc\"\nTELEGRAM_ALLOWED_USERS=555, 666\n"
        #expect(TelegramSelf.target(envText: env) == "telegram:555")
    }

    @Test func noTokenOrNoUsersMeansNoTarget() {
        #expect(TelegramSelf.target(envText: "TELEGRAM_ALLOWED_USERS=555") == nil)
        #expect(TelegramSelf.target(envText: "TELEGRAM_BOT_TOKEN=123:abc\nTELEGRAM_ALLOWED_USERS=") == nil)
        #expect(TelegramSelf.target(envText: "# TELEGRAM_BOT_TOKEN=123\n") == nil)
        #expect(TelegramSelf.target(envText: "") == nil)
    }

    @Test func notesAreKeptUnderTelegramsLimit() {
        let long = String(repeating: "a", count: 5000)
        #expect(TelegramSelf.trimmed(long).count <= 3802)
        #expect(TelegramSelf.trimmed("short") == "short")
        #expect(TelegramSelf.user(target: "telegram:5", notes: "n").hasPrefix("target: telegram:5"))
    }
}

struct MeetingListingTests {
    private func record(notes: MeetingNotes? = nil, at: Date = Date(timeIntervalSince1970: 1_788_099_300),
                        duration: Double = 1_320, failure: String? = nil, incomplete: Bool = false) -> MeetingRecord {
        var r = MeetingRecord(startedAt: at, durationSeconds: duration, folder: "/x/2026-08-30-1415",
                              notes: notes, summarised: notes != nil, summaryFailure: failure)
        r.incomplete = incomplete
        return r
    }

    // 1_788_099_300 = 30 August 2026, 14:15 UTC.
    private let utc = TimeZone(identifier: "UTC")!
    private let us = Locale(identifier: "en_US")

    /// macOS puts a narrow no-break space before AM/PM; the test compares
    /// the words, not the spacing.
    private func flat(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func theDateIsTheTitleWhenTheBrainWroteNone() {
        #expect(flat(MeetingListing.title(record(), locale: us, timeZone: utc)) == "Meeting · Aug 30, 2:15 PM")
    }

    @Test func aTitleFromTheNotesWins() {
        let notes = MeetingNotes(title: "Pricing for Q4", summary: "We settled on the tiers.")
        #expect(MeetingListing.title(record(notes: notes), locale: us, timeZone: utc) == "Pricing for Q4")
    }

    @Test func aBlankTitleFallsBackToTheDate() {
        let notes = MeetingNotes(title: "   ", summary: "s")
        #expect(MeetingListing.title(record(notes: notes), locale: us, timeZone: utc).hasPrefix("Meeting · "))
    }

    @Test func aTwentyFourHourRegionGetsATwentyFourHourLabel() {
        let label = MeetingListing.dateLabel(Date(timeIntervalSince1970: 1_788_099_300),
                                             locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(label.contains("14:15"))
        #expect(!label.lowercased().contains("pm"))
    }

    @Test func theBlurbIsTheFirstSentenceOfTheSummary() {
        let notes = MeetingNotes(title: "T", summary: "We agreed to ship on Tuesday. Dan will send the notes.")
        #expect(MeetingListing.blurb(record(notes: notes)) == "We agreed to ship on Tuesday.")
    }

    @Test func theBlurbSaysWhyWhenThereAreNoNotes() {
        #expect(MeetingListing.blurb(record(failure: "brain unavailable")) == "No notes — brain unavailable.")
        #expect(MeetingListing.blurb(record()) == "Transcript only.")
        #expect(MeetingListing.blurb(record(incomplete: true)) == "Stopped early — transcript only.")
    }

    @Test func aLongFirstSentenceIsCutOnAWordBoundary() {
        let long = String(repeating: "word ", count: 60) + "end."
        let out = MeetingListing.firstSentence(long, limit: 40)
        #expect(out.count <= 41)
        #expect(out.hasSuffix("…"))
        #expect(!out.contains("wor…"))
    }

    @Test func newlinesInTheSummaryBecomeOneLine() {
        #expect(MeetingListing.firstSentence("We met\n  about pricing and left it there") == "We met about pricing and left it there")
    }

    @Test func theListIsNewestFirst() {
        let old = record(at: Date(timeIntervalSince1970: 1_000))
        let new = record(at: Date(timeIntervalSince1970: 9_000))
        #expect(MeetingListing.sorted([old, new]).map(\.startedAt) == [new.startedAt, old.startedAt])
    }
}

/// The `LevelMeter` the two sinks carry. It used to feed the ring's
/// breathing animation (`RingLevel`, deleted with it); it now feeds the
/// health check and the 15 s level line in the log, so what matters is
/// that a drain with nothing in it is reported as nothing rather than as
/// a quiet room.
struct LevelMeterTests {

    @Test func aMeterNothingWasEverWrittenToReadsAsNoSignal() {
        let meter = LevelMeter()
        let drained = meter.drain()
        #expect(drained.frames == 0)
        #expect(drained.rms == -200)
        #expect(LevelLog.dbfs(drained.rms) == "-∞")
    }

    @Test func drainingResetsAndNeverProducesNaN() {
        let meter = LevelMeter()
        var samples = [Float](repeating: 0.5, count: 128)
        samples.withUnsafeBufferPointer { meter.add($0) }
        let loud = meter.drain()
        #expect(loud.frames == 128)
        #expect(abs(loud.rms - -6) < 0.5)        // 0.5 full scale is -6 dBFS
        // The session drains ten times a second; most of those find nothing.
        for _ in 0..<5 {
            let d = meter.drain()
            #expect(d.rms.isFinite)
            #expect(d.frames == 0)
        }
    }
}

/// The shared microphone: while a meeting records, `MicCapture` owns the
/// input device and hands the same 16 kHz mono buffers to two consumers —
/// the meeting's WAV sink and, while the user holds ⌥ to whisper, the app's
/// recogniser. There must never be a second `AVAudioEngine` on the input.
/// No device is opened here: the buffers are made by hand, which is exactly
/// the shape the resampler produces in the tap block.
struct BufferForwardTests {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: meetingSampleRate,
                                       channels: 1, interleaved: false)!

    /// One buffer of `frames` samples of a constant value — enough to tell
    /// buffers apart without generating anything anyone could hear.
    private func buffer(_ value: Float, frames: Int = 160) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.floatChannelData![0][i] = value }
        return b
    }

    @Test func nothingIsAttachedUntilSomeoneAsks() {
        let f = BufferForward()
        #expect(!f.isAttached)
        // Delivering with no consumer is the normal case — a meeting with
        // nobody whispering — and must not crash or count differently.
        f.deliver(buffer(0.1))
        #expect(f.delivered == 1)
        #expect(!f.isAttached)
    }

    @Test func theWhispererSeesEveryBufferWhileAttached() {
        let f = BufferForward()
        var seen: [Float] = []
        f.handler = { seen.append($0.floatChannelData![0][0]) }
        f.deliver(buffer(0.1))
        f.deliver(buffer(0.2))
        f.handler = nil
        f.deliver(buffer(0.3))
        #expect(seen == [0.1, 0.2])
        // The count is of buffers off the device, not of what was consumed.
        #expect(f.delivered == 3)
    }

    @Test func theMeetingsWavAndTheWhispererGetTheSameBuffers() throws {
        // The tap block does `sink.append(mono); forward.deliver(mono)` on
        // one buffer. Both consumers must see the same audio: the meeting's
        // recording must not thin out because someone is whispering, and the
        // whisper must not be recognised from a different signal.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moe-fwd-\(UUID().uuidString).wav")
        let sink = try SampleSink(url: url, epoch: Date())
        defer { sink.close(); try? FileManager.default.removeItem(at: url) }
        let f = BufferForward()
        var forwarded: [Float] = []
        f.handler = { b in forwarded.append(b.floatChannelData![0][0]) }
        for v in [Float(0.42), 0.21, 0.11] {
            let mono = buffer(v)
            sink.append(mono)
            f.deliver(mono)
        }
        #expect(sink.buffers == 3)
        #expect(sink.count == 480 + sink.leadingSilenceFrames)
        #expect(forwarded == [0.42, 0.21, 0.11])
    }

    @Test func swappingTheConsumerMidStreamLosesNothing() {
        let f = BufferForward()
        var first = 0, second = 0
        f.handler = { _ in first += 1 }
        f.deliver(buffer(0.1))
        f.handler = { _ in second += 1 }
        f.deliver(buffer(0.1))
        f.deliver(buffer(0.1))
        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func deliveringWhileTheConsumerIsSwappedDoesNotCrash() async {
        // The audio thread delivers while the main thread attaches and
        // detaches — the reason the handler is behind a lock at all.
        let f = BufferForward()
        let count = 400
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<count { f.deliver(self.buffer(0.1, frames: 16)) }
            }
            group.addTask {
                for i in 0..<count { f.handler = i.isMultiple(of: 2) ? { _ in } : nil }
            }
        }
        #expect(f.delivered == count)
    }
}
