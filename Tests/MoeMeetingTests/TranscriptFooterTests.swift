import Foundation
import Testing

@testable import MoeMeeting

@Suite("Transcript footer")
struct TranscriptFooterTests {

    private func seg(_ who: Speaker, _ t: Double = 0) -> Segment {
        Segment(start: t, end: t + 1, speaker: who, text: "something")
    }

    @Test("nothing yet")
    func empty() {
        #expect(TranscriptFooter.line([]) == "0 lines")
    }

    @Test("you and three others is four voices")
    func counts() {
        let segs = [seg(.you), seg(.them(1)), seg(.them(2)), seg(.them(3)), seg(.them(1))]
        #expect(TranscriptFooter.voices(segs) == 4)
        #expect(TranscriptFooter.line(segs) == "5 lines · 4 voices")
    }

    @Test("before diarization runs, the far end is one voice, not none and not many")
    func unnumberedThem() {
        let segs = [seg(.you), seg(.them(nil)), seg(.them(nil))]
        #expect(TranscriptFooter.voices(segs) == 2)
        #expect(TranscriptFooter.line(segs) == "3 lines · 2 voices")
    }

    /// The number that would have caught 2026-09-08's 16:10 meeting: 551
    /// lines of a six-person Telegram call, every one of them `you`,
    /// because the call-audio stream recorded nothing but zeros.
    @Test("a whole meeting on one channel says so in words")
    func onlyYou() {
        let segs = (0..<551).map { seg(.you, Double($0)) }
        #expect(TranscriptFooter.voices(segs) == 1)
        #expect(TranscriptFooter.line(segs) == "551 lines · only your voice")
    }

    @Test("a webinar the user listened to is one voice, but not theirs")
    func onlyThem() {
        let segs = [seg(.them(1)), seg(.them(1))]
        #expect(TranscriptFooter.line(segs) == "2 lines · 1 voice")
    }

    @Test("singulars")
    func singular() {
        #expect(TranscriptFooter.line([seg(.them(1))]) == "1 line · 1 voice")
    }
}
