import Foundation
import Testing
@testable import MoeVoice

/// The owner's Moe, 2026-09-23: the volume pumped loud/quiet through replies.
/// moe.log had 40 "sound over speaking … let go — rejected-no-words" that day
/// (29 in the 14:00 hour, two in the first ~2 s of the 15:35 reply), and each
/// ducked the reply to −14 dB for the 1 s word window. Of 54 such clips, 36
/// were under −46 dBFS — the canceller's residue of Moe's own voice. A bare
/// VAD onset over a reply now ducks nothing; the first word does.
struct DuckPumpingTests {

    typealias M = VoiceMachine

    private func speaking() -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { return m }
        _ = m.handle(.transcribed(turn: turn, "how does that work"))
        _ = m.handle(.speechQueued)
        return m
    }

    private func ducks(_ out: [M.Action]) -> Int {
        out.filter { $0 == .duckSpeech(true) }.count
    }

    /// The log's shape: onsets at the start of the reply and through it, the
    /// VAD flapping, never a word. Zero ducks, and the reply never paused.
    @Test func onsetsWithNoWordsNeverDuckTheReply() {
        var m = speaking()
        var all: [M.Action] = []
        for _ in 0..<6 {
            all += m.handle(.speechStarted)
            all += m.handle(.speechEnded)
            all += m.handle(.timer(.bargeInHold))
        }
        #expect(ducks(all) == 0)
        #expect(!all.contains(.pauseSpeech))
        #expect(all.filter { $0 == .onsetRejected(.noWords) }.count == 6)
        #expect(m.state == .speaking(.hotkey))
    }

    /// A real interruption: the first word ducks, the second (or a stop
    /// word) is judged, and a "for Moe" pauses the reply.
    @Test func theFirstWordDucksAndThenItStops() {
        var m = speaking()
        #expect(ducks(m.handle(.speechStarted)) == 0)
        let first = m.handle(.wordsHeard(1))
        #expect(ducks(first) == 1)
        let second = m.handle(.wordsHeard(2))
        #expect(second.contains(.judgeBargeIn))
        let judged = m.handle(.bargeInJudged(true))
        #expect(judged.contains(.pauseSpeech))
    }

    @Test func aStopWordDucksAndIsJudgedAtOnce() {
        var m = speaking()
        _ = m.handle(.speechStarted)
        let stop = m.handle(.wordsHeard(1, urgent: true))
        #expect(ducks(stop) == 1)
        #expect(stop.contains(.judgeBargeIn))
    }
}
