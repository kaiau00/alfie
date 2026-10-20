import Foundation
import Testing
@testable import MoeVoice

/// Failure 2 of the 2026-09-22 voice audit: in background noise Moe never
/// knows the person has finished.
///
/// Endpointing was VAD-only: the turn model was asked when the VAD reported
/// a pause, and steady noise keeps the VAD "in speech" for good. Every VAD
/// re-onset also cancelled whatever clock a "mid-thought" verdict had armed.
/// Measured in the owner's log (2026-09-07 11:48Z): a 53.0 s capture with
/// eleven mid-thought verdicts, then a 34.7 s capture over wordless noise.
struct NoiseEndpointTests {

    typealias M = VoiceMachine
    typealias A = M.Action

    private func capturing(turnModel: Bool = true) -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.turnModel = turnModel
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        return m
    }

    private func decided(_ out: [A]) -> M.EndReason? {
        for a in out { if case .decided(let r) = a { return r } }
        return nil
    }

    private func transcribes(_ out: [A]) -> Bool {
        out.contains { if case .transcribe = $0 { return true }; return false }
    }

    // MARK: The stall clock

    @Test func wordsStoppingAsksTheTurnModelWhateverTheVadSays() {
        var m = capturing()
        // Words arrive; the VAD never reports a pause (a fan behind them).
        let words = m.handle(.wordsHeard(3))
        #expect(words.contains(.armTimer(.wordStall, seconds: 1.3)))
        let stalled = m.handle(.timer(.wordStall))
        #expect(stalled.contains(.askTurnModelOnStall))
        #expect(stalled.contains(.armTimer(.silence, seconds: 1.5)))
        // "Finished": the turn ends, and says it was the stall.
        let out = m.handle(.turnVerdict(complete: true))
        #expect(transcribes(out))
        #expect(decided(out) == .stall)
    }

    @Test func withoutATurnModelTheStallStillEndsTheTurn() {
        var m = capturing(turnModel: false)
        _ = m.handle(.wordsHeard(2))
        let stalled = m.handle(.timer(.wordStall))
        #expect(!stalled.contains(.askTurnModelOnStall))
        let out = m.handle(.timer(.silence))
        #expect(transcribes(out))
        #expect(decided(out) == .stall)
    }

    @Test func moreWordsPushTheStallBack() {
        var m = capturing()
        _ = m.handle(.wordsHeard(2))
        let more = m.handle(.wordsHeard(4))
        #expect(more.contains(.armTimer(.wordStall, seconds: 1.3)))
    }

    // MARK: Noise cannot cancel the ceiling

    /// The 53 s capture: every VAD re-onset cancelled the clock the
    /// "mid-thought" verdict armed. Now only words can.
    @Test func aFlappingVadCannotHoldAMidThoughtOpen() {
        var m = capturing()
        _ = m.handle(.wordsHeard(5))
        _ = m.handle(.speechEnded)
        let verdict = m.handle(.turnVerdict(complete: false, stillMidClause: true))
        #expect(verdict.contains(.armTimer(.silence, seconds: 6.0)))
        var all: [A] = []
        for _ in 0..<10 {                     // the room flaps; no words
            all += m.handle(.speechStarted)
            all += m.handle(.speechEnded)
        }
        #expect(!all.contains(.cancelTimer(.silence)))
        // The clock fires: one short reprieve for the last onset…
        let first = m.handle(.timer(.silence))
        #expect(first.contains(.armTimer(.silence, seconds: 0.8)))
        #expect(!transcribes(first))
        // …and then the turn ends, as a ceiling.
        let out = m.handle(.timer(.silence))
        #expect(transcribes(out))
        #expect(decided(out) == .ceiling)
    }

    @Test func wordsAfterAnOnsetStillKeepTheTurnGoing() {
        var m = capturing()
        _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        _ = m.handle(.turnVerdict(complete: false))
        _ = m.handle(.speechStarted)          // the person, going on
        let words = m.handle(.wordsHeard(5))
        #expect(words.contains(.cancelTimer(.silence)))
        #expect(!transcribes(m.handle(.timer(.silence))))
        #expect(m.state == .capturing(.hotkey))
    }

    /// Review H4: over a TV, the noise-floor gate ends speech while the
    /// person is still talking at the TV's level, then refuses an onset for a
    /// voice no louder than the room. The words kept coming and the 1.5 s
    /// clock cut the turn mid-sentence. Words cancel the clock, VAD or not.
    @Test func wordsCancelTheEndingClockEvenWithTheVadQuiet() {
        var m = capturing()
        _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)            // the gate's forced end
        let more = m.handle(.wordsHeard(5))   // no onset: still talking
        #expect(more.contains(.cancelTimer(.silence)))
        #expect(more.contains(.armTimer(.wordStall, seconds: 1.3)))
        #expect(!m.handle(.timer(.silence)).contains { if case .transcribe = $0 { return true }; return false })
        #expect(m.state == .capturing(.hotkey))
    }

    /// Review L4: "ummm… uhhh" is still somebody talking — fillers push the
    /// stall back even though they are not words that end anything.
    @Test func fillersPushTheStallBack() {
        var m = capturing()
        _ = m.handle(.wordsHeard(2))
        #expect(m.handle(.wordsGrew).contains(.armTimer(.wordStall, seconds: 1.3)))
    }

    /// Review M5: in a language the streaming recogniser cannot write, a
    /// capture with no words is read, not dropped.
    @Test func aWordlessCaptureIsReadWhereTheRecogniserCannotWrite() {
        var m = capturing()
        m.tuning.readWordlessCaptures = true
        let out = m.handle(.timer(.noWords))
        #expect(transcribes(out))
        #expect(decided(out) == .noWords)
    }

    @Test func theDanglingVerdictHoldIsNotCancelledBySound() {
        var m = capturing()
        _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        _ = m.handle(.turnVerdict(complete: true, stillMidClause: true))
        let onset = m.handle(.speechStarted)
        #expect(!onset.contains(.cancelTimer(.verdictHold)))
        _ = m.handle(.timer(.verdictHold))    // the one reprieve
        let out = m.handle(.timer(.verdictHold))
        #expect(decided(out) == .verdictHold)
    }

    // MARK: No words at all

    @Test func soundWithNoWordsEndsSilently() {
        var m = M()
        m.tuning.conversation = true
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(3))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "what time is it"))
        _ = m.handle(.brainFinished)
        #expect(m.state == .followUp)
        // A fan starts in the window: a capture opens on sound…
        let opened = m.handle(.speechStarted)
        #expect(m.state == .capturing(.followUp))
        #expect(opened.contains(.armTimer(.noWords, seconds: 3.5)))
        // …and no word ever comes. No read, no turn: back to the window.
        let out = m.handle(.timer(.noWords))
        #expect(!transcribes(out))
        #expect(decided(out) == .noWords)
        #expect(!out.contains { if case .submit = $0 { return true }; return false })
        #expect(m.state == .followUp)
    }

    @Test func aWordCancelsTheNoWordsClock() {
        var m = capturing()
        let words = m.handle(.wordsHeard(1))
        #expect(words.contains(.cancelTimer(.noWords)))
        #expect(m.handle(.timer(.noWords)).isEmpty)
        #expect(m.state == .capturing(.hotkey))
    }

    @Test func aWakeCaptureStartsItsNoWordsClockWhenTheRequestStarts() {
        var m = M()
        _ = m.handle(.setWake(true))
        _ = m.handle(.woke)
        let started = m.handle(.speechStarted)
        #expect(started.contains(.armTimer(.noWords, seconds: 3.5)))
        #expect(started.contains(.cancelTimer(.silence)))
    }

    // MARK: Reasons

    @Test func everyDecisionSaysWhy() {
        var m = capturing()
        _ = m.handle(.speechEnded)
        #expect(decided(m.handle(.timer(.silence))) == .vad)

        var n = capturing()
        _ = n.handle(.speechEnded)
        #expect(decided(n.handle(.turnVerdict(complete: true))) == .turnModel)

        var c = capturing()
        #expect(decided(c.handle(.timer(.turnCap))) == .cap)

        var k = M()
        _ = k.handle(.holdDown)
        #expect(decided(k.handle(.holdUp)) == .key)
    }

    /// `continuationOpen` is untouched: a turn decided at a breath still
    /// joins its second half, which arrives as words.
    @Test func theContinuationWindowStillJoinsTheHalves() {
        var m = capturing()
        _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))
        _ = m.handle(.transcribed(turn: turn, "I'm in the garden"))
        #expect(m.state == .capturing(.hotkey))
        _ = m.handle(.speechEnded)
        _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let t2) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: t2, "and it is sunny"))
        #expect(out.contains(.submit("I'm in the garden and it is sunny")))
    }
}
