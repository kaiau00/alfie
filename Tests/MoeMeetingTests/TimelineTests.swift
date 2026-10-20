import Foundation
import Testing
@testable import MoeMeeting

struct TimelineTests {

    // MARK: Tokens → segments

    @Test func sentencePieceTokensJoinIntoWords() {
        let tokens = [TimedToken("▁We", 0.0, 0.2), TimedToken("▁agreed", 0.25, 0.6),
                      TimedToken("▁to", 0.65, 0.7), TimedToken("▁ship", 0.75, 1.0), TimedToken(".", 1.0, 1.05)]
        let segs = Timeline.segments(from: tokens, speaker: .them(nil))
        #expect(segs.count == 1)
        #expect(segs[0].text == "We agreed to ship")
        #expect(segs[0].start == 0.0)
        #expect(segs[0].end == 1.05)
        #expect(segs[0].speaker == .them(nil))
    }

    @Test func pauseSplitsSegmentsAndDropsStrayPunctuation() {
        let tokens = [TimedToken("▁Sounds", 0.0, 0.3), TimedToken("▁good", 0.35, 0.6),
                      TimedToken(".", 1.6, 1.65),                       // lands after the pause
                      TimedToken("▁I", 1.7, 1.8), TimedToken("▁will", 1.85, 2.0)]
        let segs = Timeline.segments(from: tokens, speaker: .you, gap: 0.8)
        #expect(segs.map(\.text) == ["Sounds good", "I will"])
        #expect(segs[1].start == 1.6)
    }

    @Test func offsetShiftsIntoTheMeetingClock() {
        let segs = Timeline.segments(from: [TimedToken("▁hi", 1.0, 1.4)], speaker: .you, offset: 60)
        #expect(segs[0].start == 61.0)
        #expect(segs[0].end == 61.4)
        #expect(segs[0].line == "[01:01] you: hi")
    }

    @Test func emptyAndPunctuationOnlyTokensGiveNothing() {
        #expect(Timeline.segments(from: [], speaker: .you).isEmpty)
        #expect(Timeline.segments(from: [TimedToken(".", 0, 0.1), TimedToken("▁", 0.2, 0.3)], speaker: .you).isEmpty)
    }

    // MARK: Merge

    @Test func mergeOrdersByStartAcrossStreams() {
        let you = [Segment(start: 6.0, end: 8.0, speaker: .you, text: "sounds good")]
        let them = [Segment(start: 0.0, end: 5.0, speaker: .them(nil), text: "ship on Tuesday"),
                    Segment(start: 9.0, end: 10.0, speaker: .them(nil), text: "thanks")]
        let merged = Timeline.merge(you, them)
        #expect(merged.map(\.text) == ["ship on Tuesday", "sounds good", "thanks"])
    }

    @Test func mergeIsStableForEqualStartsYouFirst() {
        let them = [Segment(start: 3.0, end: 4.0, speaker: .them(nil), text: "b")]
        let you = [Segment(start: 3.0, end: 4.0, speaker: .you, text: "a")]
        #expect(Timeline.merge(them, you).map(\.text) == ["a", "b"])
        #expect(Timeline.merge(you, them).map(\.text) == ["a", "b"])
    }

    // MARK: Diarization relabel

    @Test func relabelNumbersSpeakersByFirstAppearance() {
        let segs = [Segment(start: 0, end: 5, speaker: .them(nil), text: "one"),
                    Segment(start: 6, end: 8, speaker: .them(nil), text: "two"),
                    Segment(start: 6.5, end: 7, speaker: .you, text: "me")]
        // The diarizer called the first voice "S7" and the second "S2".
        let spans = [SpeakerSpan("S2", 5.8, 8.2), SpeakerSpan("S7", 0, 5.2)]
        let out = Timeline.relabel(segs, with: spans)
        #expect(out[0].speaker == .them(1))
        #expect(out[1].speaker == .them(2))
        #expect(out[2].speaker == .you)          // never touched
        #expect(out[0].line == "[00:00] them (speaker 1): one")
    }

    @Test func relabelPicksTheLargestOverlapThenTheNearest() {
        let segs = [Segment(start: 4, end: 6, speaker: .them(nil), text: "straddles"),
                    Segment(start: 20, end: 21, speaker: .them(nil), text: "outside")]
        let spans = [SpeakerSpan("A", 0, 4.5), SpeakerSpan("B", 4.5, 10)]
        let out = Timeline.relabel(segs, with: spans)
        #expect(out[0].speaker == .them(2))       // 1.5 s with B beats 0.5 s with A
        #expect(out[1].speaker == .them(2))       // nothing overlaps; B's midpoint is nearer
    }

    @Test func relabelWithNoSpansLeavesThemUnnumbered() {
        let segs = [Segment(start: 0, end: 1, speaker: .them(nil), text: "x")]
        #expect(Timeline.relabel(segs, with: []) == segs)
        #expect(Timeline.speakerNumbers(segs) == [])
    }

    // MARK: Formatting and parsing

    @Test func clockGrowsPastAnHour() {
        #expect(Timeline.clock(0) == "00:00")
        #expect(Timeline.clock(65.9) == "01:05")
        #expect(Timeline.clock(3723) == "62:03")
        #expect(Timeline.clock(-4) == "00:00")
    }

    @Test func formatIsOneLinePerSegment() {
        let segs = [Segment(start: 0, end: 5, speaker: .them(1), text: "Testing 123"),
                    Segment(start: 6, end: 8, speaker: .you, text: "Sounds good")]
        #expect(Timeline.format(segs) == "[00:00] them (speaker 1): Testing 123\n[00:06] you: Sounds good")
        #expect(Timeline.format([]) == "")
    }

    @Test func parseRoundTripsWhatFormatWrote() {
        let text = """
        [00:00] them (speaker 1): Testing 123. This is the system audio
        [00:06] them (speaker 2): Sounds good: I will send the notes
        [00:07] you: thanks
        junk line
        [00:09] them: unnumbered
        """
        let segs = Timeline.parse(text)
        #expect(segs.count == 4)
        #expect(segs[0].speaker == .them(1))
        #expect(segs[1].text == "Sounds good: I will send the notes")
        #expect(segs[2].speaker == .you)
        #expect(segs[3].speaker == .them(nil))
        #expect(segs[0].end == 6)
        #expect(segs[3].end == 9)
        #expect(Timeline.speakerNumbers(segs) == [1, 2])
    }

    // MARK: Windows

    @Test func bestCutFindsTheQuietestPointNearTheEnd() {
        // 10 s of tone with 100 ms of silence at 8.5 s.
        let rate = 16_000
        var samples = (0..<(10 * rate)).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        for i in (Int(8.5 * Double(rate)))..<(Int(8.6 * Double(rate))) { samples[i] = 0 }
        let cut = Windowing.bestCut(samples, searchSeconds: 3)
        #expect(cut > Int(8.4 * Double(rate)) && cut < Int(8.7 * Double(rate)))
    }

    @Test func bestCutOnAShortBufferIsTheEnd() {
        let samples = [Float](repeating: 0.1, count: 16_000)
        #expect(Windowing.bestCut(samples, searchSeconds: 3) == samples.count)
    }

    @Test func silenceDetection() {
        #expect(Windowing.isSilent([]))
        #expect(Windowing.isSilent([Float](repeating: 0, count: 1000)))
        #expect(Windowing.isSilent([Float](repeating: 0.0005, count: 1000)))   // -66 dBFS
        #expect(!Windowing.isSilent([Float](repeating: 0.01, count: 1000)))    // -40 dBFS
    }

    // MARK: Drift

    @Test func driftReportMathAndNote() {
        // 60 minutes, mic 180 ms longer: 50 ppm.
        let d = DriftReport(systemSeconds: 3600, micSeconds: 3600.18, wallSeconds: 3600)
        #expect(abs(d.differenceSeconds - 0.18) < 1e-9)
        #expect(abs(d.partsPerMillion - 50) < 0.01)
        #expect(d.isNoteworthy)
        #expect(d.note.contains("mic ran ahead"))
        #expect(d.note.contains("180 ms"))
        #expect(d.note.contains("60:00"))
        #expect(d.note.contains("50 ppm"))
    }

    @Test func driftBelowThresholdHasNoNote() {
        let d = DriftReport(systemFrames: 16_000 * 600, micFrames: 16_000 * 600 + 800, wallSeconds: 600)
        #expect(abs(d.differenceSeconds - 0.05) < 1e-9)
        #expect(!d.isNoteworthy)
        #expect(d.note == "")
        let other = DriftReport(systemSeconds: 100.5, micSeconds: 100, wallSeconds: 100)
        #expect(other.note.contains("call audio ran ahead"))
        #expect(DriftReport(systemSeconds: 1, micSeconds: 2, wallSeconds: 0).partsPerMillion == 0)
    }
}

@Suite struct EchoSuppressionTests {
    private func you(_ t: String, _ a: Double, _ b: Double) -> Segment {
        Segment(start: a, end: b, speaker: .you, text: t)
    }
    private func them(_ t: String, _ a: Double, _ b: Double) -> Segment {
        Segment(start: a, end: b, speaker: .them(nil), text: t)
    }

    @Test func theRealCaseFromTheFirstControlledTest() {
        // Verbatim from ~/.moe/meetings/2026-08-30-1646: the user was only
        // playing a recording and said nothing, yet the opening of the far
        // end's sentence was written under `you`.
        let far = "By the way, I was thinking that just going forward, we should try to ask more abstract questions"
        let out = Timeline.withoutEcho([you("By the way, I was thinking that just", 12, 14),
                                        them(far, 12, 29)])
        #expect(out.count == 1)
        #expect(!out.contains { $0.speaker.isYou })
    }

    @Test func punctuationAndCasingDoNotSaveTheEcho() {
        #expect(Timeline.withoutEcho([you("so, Anyway -- we should ship it", 3, 5),
                                      them("So anyway we should ship it tomorrow", 3, 8)])
                    .allSatisfy { !$0.speaker.isYou })
    }

    @Test func aShortAgreementIsNotEcho() {
        // Two people really do both say this; below the word floor it stays.
        let out = Timeline.withoutEcho([you("Yeah exactly", 10, 11),
                                        them("Yeah exactly right", 10, 12)])
        #expect(out.count == 2)
    }

    @Test func theUserSayingSomethingElseIsKept() {
        let out = Timeline.withoutEcho([you("I think we should push the date instead", 4, 7),
                                        them("By the way I was thinking about the budget", 4, 9)])
        #expect(out.count == 2)
    }

    @Test func theSameWordsFarApartInTimeAreKept() {
        // Someone quoting the far end back, a minute later, is not echo.
        let out = Timeline.withoutEcho([you("we should try to ask more abstract questions", 300, 303),
                                        them("we should try to ask more abstract questions", 12, 20)])
        #expect(out.count == 2)
    }

    @Test func nothingFromThemMeansNothingToCompareAgainst() {
        let only = [you("a whole sentence of my own words here", 1, 4)]
        #expect(Timeline.withoutEcho(only).count == 1)
    }

    @Test func themLinesAreNeverDropped() {
        let out = Timeline.withoutEcho([them("one two three four five", 1, 3),
                                        them("one two three four five", 1, 3)])
        #expect(out.count == 2)
    }
}
