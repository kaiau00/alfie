import Foundation
import Testing
@testable import MoeVoice

/// 2026-10-07 21:48:40Z: a 35-word request in the follow-up window, about
/// twelve seconds of speech, was measured by its last VAD segment — under a
/// second — and dropped as "not for Moe" at level 0.16 with no owner or
/// anchor score. The span is the whole turn.
struct TurnSpeechSpanTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aTurnWithPausesIsMeasuredWhole() {
        // Twelve seconds of speech, the last segment a 0.6 s trailing phrase.
        let s = TurnAudio.speechSeconds(turnStarted: t0, turnEnded: t0.addingTimeInterval(12.1),
                                        lastSegment: 0.6, segmentBegan: t0.addingTimeInterval(11.5),
                                        now: t0.addingTimeInterval(12.6))
        #expect(abs(s - 12.1) < 0.001)
        // Long enough for the owner and anchor checks, which need a second.
        #expect(s >= 1)
    }

    @Test func withoutASpanTheLastSegmentStands() {
        let s = TurnAudio.speechSeconds(turnStarted: nil, turnEnded: nil, lastSegment: 0.6,
                                        segmentBegan: nil, now: t0)
        #expect(s == 0.6)
    }

    @Test func stillSpeakingCountsToNow() {
        let s = TurnAudio.speechSeconds(turnStarted: t0, turnEnded: nil, lastSegment: 0,
                                        segmentBegan: t0, now: t0.addingTimeInterval(3))
        #expect(abs(s - 3) < 0.001)
    }
}
