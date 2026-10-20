import Foundation
import Testing
@testable import MoeMeeting

struct SpeakerSplitTests {

    @Test func tokensSplitWhereTheDiarizerSaysTheSpeakerChanged() {
        // One recognised stretch, no pause, two voices: 0–4.6 s and 4.8 s on.
        let tokens = [TimedToken("▁ship", 4.0, 4.3), TimedToken("▁Tuesday", 4.3, 4.6),
                      TimedToken("▁Sounds", 4.8, 5.1), TimedToken("▁good", 5.1, 5.4)]
        let lookup = Timeline.speakerLookup([SpeakerSpan("x", 0, 4.7), SpeakerSpan("y", 4.7, 10)])
        let segs = Timeline.segments(from: tokens, speakerAt: lookup)
        #expect(segs.map(\.text) == ["ship Tuesday", "Sounds good"])
        #expect(segs.map(\.speaker) == [.them(1), .them(2)])
    }

    @Test func lookupUsesContainingSpanThenNearest() {
        let lookup = Timeline.speakerLookup([SpeakerSpan("b", 10, 20), SpeakerSpan("a", 0, 5)])
        #expect(lookup(2) == .them(1))      // "a" spoke first → 1
        #expect(lookup(15) == .them(2))
        #expect(lookup(7) == .them(1))      // gap: nearer a's midpoint (2.5) than b's (15)
        #expect(lookup(9.5) == .them(2))
        #expect(Timeline.speakerLookup([])(3) == .them(nil))
    }

    @Test func offsetAppliesBeforeTheLookup() {
        let lookup = Timeline.speakerLookup([SpeakerSpan("a", 0, 50), SpeakerSpan("b", 50, 100)])
        let segs = Timeline.segments(from: [TimedToken("▁late", 1, 2)], offset: 60, speakerAt: lookup)
        #expect(segs[0].speaker == .them(2))
        #expect(segs[0].start == 61)
    }

    @Test func speechGateRejectsFaintLeakAndAcceptsSpeech() {
        let rate = 16_000
        let faint = (0..<(3 * rate)).map { Float(sin(Double($0) * 0.3)) * 0.003 }     // ≈ -53 dBFS
        #expect(!Windowing.hasSpeech(faint))
        var speech = faint
        for i in (rate)..<(rate + rate / 2) { speech[i] = Float(sin(Double(i) * 0.3)) * 0.1 }   // 0.5 s at ≈ -23 dBFS
        #expect(Windowing.hasSpeech(speech))
        #expect(!Windowing.hasSpeech(speech, minFrames: 8))     // only 5 loud frames
        #expect(!Windowing.hasSpeech([]))
    }
}

struct BookmarkTests {

    let segs = [Segment(start: 0, end: 5, speaker: .them(1), text: "we agreed to ship the meeting feature on Tuesday"),
                Segment(start: 6, end: 8, speaker: .them(2), text: "sounds good I will send the notes"),
                Segment(start: 60, end: 62, speaker: .you, text: "thanks everyone")]

    @Test func labelIsTheLastWordsHeardBeforeTheMark() {
        #expect(Bookmarks.label(for: 7, in: segs) == "send the notes")
        #expect(Bookmarks.label(for: 4, in: segs) == "feature on Tuesday")
        #expect(Bookmarks.label(for: 61, in: segs, words: 2) == "thanks everyone")
    }

    @Test func labelFallsBackToWhatFollowsOrNothing() {
        #expect(Bookmarks.label(for: 40, in: segs) == "thanks everyone")      // next within 20 s
        #expect(Bookmarks.label(for: 30, in: segs) == "")                      // 22 s after the last, 30 before the next
        #expect(Bookmarks.label(for: 3, in: []) == "")
    }

    @Test func labelledKeepsGivenLabelsAndFillsEmptyOnes() {
        let out = Bookmarks.labelled([Bookmark(time: 7), Bookmark(time: 4, label: "keep me")], in: segs)
        #expect(out[0].label == "send the notes")
        #expect(out[1].label == "keep me")
        #expect(out[0].line == "[00:07] send the notes")
        #expect(Bookmark(time: 90).line == "[01:30] bookmark")
    }

    @Test func bookmarksReachThePromptAndTheNotes() {
        let marks = [Bookmark(time: 7, label: "send the notes")]
        let user = MeetingSummaryPrompt.user(transcript: "x", date: Date(), duration: 10, bookmarks: marks)
        #expect(user.contains("bookmarked these moments"))
        #expect(user.contains("[00:07] send the notes"))
        #expect(!MeetingSummaryPrompt.user(transcript: "x", date: Date(), duration: 10).contains("bookmarked"))
        let md = MeetingNotes(title: "T", summary: "S").markdown(date: Date(), duration: 10, bookmarks: marks)
        #expect(md.contains("## Bookmarks\n\n- [00:07] send the notes"))
    }
}

struct ChannelHealthTests {

    @Test func quietChannelsAreNamedAfterTwentySeconds() {
        var h = ChannelHealth(quietAfter: 20)
        h.observe(micDb: -30, systemDb: -25, at: 0)
        #expect(h.status(at: 10) == "")
        #expect(h.status(at: 20) == "mic silent · no meeting audio")
        h.observe(micDb: -30, systemDb: -25, at: 21)          // both heard again
        #expect(h.status(at: 30) == "")
        h.observe(micDb: -30, systemDb: -80, at: 35)          // call goes quiet, user keeps talking
        h.observe(micDb: -30, systemDb: -80, at: 40)
        #expect(h.status(at: 41) == "no meeting audio")       // 20 s since the call last sounded (21)
        h.observe(micDb: -80, systemDb: -20, at: 45)          // the reverse
        #expect(h.status(at: 50) == "")                        // mic last heard at 40: only 10 s
        #expect(h.status(at: 60) == "mic silent")
    }

    @Test func nothingHeardYetCountsFromZero() {
        let h = ChannelHealth(quietAfter: 20)
        #expect(h.status(at: 5) == "")
        #expect(h.status(at: 20) == "mic silent · no meeting audio")
        #expect(h.status(at: 20, paused: true) == "")
    }

    @Test func thresholdIsAdjustable() {
        var h = ChannelHealth(quietAfter: 20, soundDb: -40)
        h.observe(micDb: -45, systemDb: -35, at: 0)
        #expect(h.lastMicSound == nil)
        #expect(h.lastSystemSound == 0)
    }
}

struct PauseLogTests {

    @Test func spansCloseOnResumeAndNoteReadsRight() {
        var log = PauseLog()
        #expect(!log.isOpen)
        log.resume(at: 3)                       // nothing open: ignored
        log.pause(at: 70)
        log.pause(at: 80)                       // already open: ignored
        #expect(log.isOpen)
        log.resume(at: 125)
        log.pause(at: 420); log.resume(at: 450)
        #expect(log.spans == [.init(start: 70, end: 125), .init(start: 420, end: 450)])
        #expect(log.totalSeconds == 85)
        #expect(log.covers(100))
        #expect(!log.covers(125))
        #expect(!log.covers(10))
        #expect(log.note == "Off the record: 01:10–02:05, 07:00–07:30 (01:25 in all, nothing kept).")
        #expect(PauseLog().note == "")
    }

    @Test func resumeBeforePauseTimeClampsToZeroLength() {
        var log = PauseLog()
        log.pause(at: 50); log.resume(at: 40)
        #expect(log.spans == [.init(start: 50, end: 50)])
        #expect(log.totalSeconds == 0)
    }

    @Test func recordCarriesTakerBookmarksAndPauses() throws {
        var r = MeetingRecord(startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 10, folder: "/x",
                              bookmarks: [Bookmark(time: 3, label: "l")], offTheRecord: [.init(start: 1, end: 2)])
        r.summarised = true
        let text = try #require(String(data: try r.json(), encoding: .utf8))
        #expect(text.contains("\"taker\" : \"moe-agent\""))
        #expect(text.contains("\"offTheRecord\""))
        let back = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(text.utf8))
        #expect(back == r)
        #expect(back.taker == "moe-agent")
    }
}

struct MeetingOwnerTests {

    @Test func nameFromUserMD() {
        #expect(MeetingOwner.name(fromUserMD: "Name: Jordan Avery. Goes by Jordy.\n§\nAge: 20") == "Jordy")
        #expect(MeetingOwner.name(fromUserMD: "Name: Dan\n") == "Dan")
        #expect(MeetingOwner.name(fromUserMD: "name: Anna-Maria Vogel (she/her)") == "Anna-Maria")
        #expect(MeetingOwner.name(fromUserMD: "Lives in Berlin.\n") == nil)
        #expect(MeetingOwner.name(fromUserMD: "") == nil)
        #expect(MeetingOwner.name(fromUserMD: "Name:   ") == nil)
    }

    @Test func assistantLabelAndAnnouncement() {
        #expect(MeetingOwner.assistantLabel(userName: "Jordy") == "Jordy's assistant")
        #expect(MeetingOwner.assistantLabel(userName: "James") == "James' assistant")
        #expect(MeetingOwner.assistantLabel(userName: nil) == "my assistant")
        #expect(MeetingOwner.assistantLabel(userName: "  ") == "my assistant")
        #expect(MeetingOwner.announcement(userName: "Jordy").hasPrefix("Jordy's assistant is taking notes for this meeting."))
        #expect(MeetingOwner.announcement(userName: nil) == "My assistant is taking notes for this meeting. The recording stays on my Mac.")
    }
}

// MARK: - Sample sink (the file the audio threads write)

import AVFoundation

struct SampleSinkTests {
    func buffer(_ value: Float, frames: Int) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: meetingSampleRate, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.floatChannelData![0][i] = value }
        return b
    }

    /// Two buffers, one of them off the record, a lead-in from the epoch:
    /// the file reads back as exactly that, header patched at close.
    @Test func streamsToAValidWavWithLeadInAndMute() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moe-sink-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try SampleSink(url: url, epoch: Date().addingTimeInterval(-0.5))
        sink.append(buffer(0.5, frames: 1600))
        sink.muted = true
        sink.append(buffer(0.5, frames: 800))
        sink.muted = false
        sink.append(buffer(-0.25, frames: 20_000))   // bigger than the scratch buffer
        sink.close()
        sink.close()   // idempotent
        #expect(sink.buffers == 3)
        let lead = sink.leadingSilenceFrames
        #expect(lead >= 7_900 && lead <= 9_000)
        #expect(sink.count == lead + 1600 + 800 + 20_000)
        let samples = try Wav.read(url)
        #expect(samples.count == sink.count)
        #expect(samples[lead - 1] == 0)
        #expect(abs(samples[lead] - 0.5) < 0.001)
        #expect(samples[lead + 1600] == 0)             // muted stretch is silence on disk
        #expect(samples[lead + 1600 + 799] == 0)
        #expect(abs(samples[lead + 2400] + 0.25) < 0.001)
        #expect(abs(samples[sink.count - 1] + 0.25) < 0.001)
        // A meter never sees the muted audio.
        let (rms, _, frames) = sink.meter.drain()
        #expect(frames == 1600 + 20_000)
        #expect(rms > -20)
    }
}
