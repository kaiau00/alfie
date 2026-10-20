import Foundation
import Testing
@testable import MoeVoice

/// Failure 1 of the 2026-09-22 voice audit: non-speech noise makes Moe stop.
///
/// A VAD onset is only a sound. While Moe is thinking, while the first half
/// of a turn is being read back, and while the reply plays, a sound may
/// *duck* the reply and switch the recogniser on — nothing more. Words take
/// the floor; a word window that closes with none lets everything carry on.
/// Measured on the owner's log before this: 148 thinking-state onsets took
/// the floor, 83 of them came back with no words and held the reply 2–25 s.
struct NoiseBargeInTests {

    typealias M = VoiceMachine

    private func machine(conversation: Bool = true, bargeIn: Bool = false) -> M {
        var m = M()
        m.tuning.conversation = conversation
        m.tuning.bargeIn = bargeIn
        _ = m.handle(.setWake(false))
        return m
    }

    private func toThinking(_ m: inout M, text: String = "what time is it") {
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, text))
    }

    private func isCapturing(_ s: M.State) -> Bool {
        if case .capturing = s { return true }
        return false
    }

    // MARK: Words

    @Test func onlyWordsThatCouldTakeTheFloorCount() {
        #expect(TurnPolicy.meaningfulWords(in: "") == 0)
        #expect(TurnPolicy.meaningfulWords(in: "um uh hmm") == 0)
        #expect(TurnPolicy.meaningfulWords(in: "a") == 0)            // what noise decodes to
        #expect(TurnPolicy.meaningfulWords(in: "yeah") == 0)         // a nod
        #expect(TurnPolicy.meaningfulWords(in: "yeah okay") == 0)
        #expect(TurnPolicy.meaningfulWords(in: "stop") == 1)
        #expect(TurnPolicy.meaningfulWords(in: "no wait") == 2)
        #expect(TurnPolicy.meaningfulWords(in: "yeah but no") == 3)
        #expect(TurnPolicy.meaningfulWords(in: "7") == 1)
        // Only what came after the baseline.
        #expect(TurnPolicy.meaningfulWords(in: "what time is it", after: 4) == 0)
        #expect(TurnPolicy.meaningfulWords(in: "what time is it in tokyo", after: 4) == 2)
        // Every script is words: stripping Hebrew to nothing made every
        // follow-up in it look empty once already.
        #expect(TurnPolicy.meaningfulWords(in: "עצור בבקשה") == 2)
        #expect(TurnPolicy.meaningfulWords(in: "подожди") == 1)
    }

    // MARK: Thinking

    @Test func aSoundWhileMoeThinksHoldsNothing() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        let out = m.handle(.speechStarted)
        // Still thinking: the reply is not held, the turn is not reopened.
        #expect(m.state == .thinking(.hotkey))
        #expect(out.contains(.armTimer(.bargeInHold, seconds: 1.0)))
        // Before the first word of a reply the microphone is already open
        // for the turn going on; the recogniser keeps the first half.
        #expect(!out.contains(.resetAsr))
        // The window closes with no words: nothing happened.
        let closed = m.handle(.timer(.bargeInHold))
        #expect(m.state == .thinking(.hotkey))
        #expect(!closed.contains(.resumeReply))
        #expect(!closed.contains(.abandonReply))
        // The reply arrives and plays as if nothing happened.
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
    }

    /// Once the reply has been heard in part and has parked (audio ran out,
    /// the brain is still writing), a sound switches the recogniser on to
    /// listen — and off again when no words come.
    @Test func aSoundOverAParkedReplyListensAndLetsGo() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .thinking(.hotkey))
        let out = m.handle(.speechStarted)
        #expect(out.contains(.asr(true)))
        #expect(out.contains(.capture(true)))
        #expect(out.contains(.resetAsr))
        let closed = m.handle(.timer(.bargeInHold))
        #expect(closed.contains(.asr(false)))
        #expect(closed.contains(.capture(false)))
        #expect(m.state == .thinking(.hotkey))
    }

    @Test func wordsWhileMoeThinksGoOnWithTheTurn() {
        var m = machine()          // barge-in off: the continuation needs no barge-in
        toThinking(&m, text: "add milk")
        _ = m.handle(.speechStarted)
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.wordsHeard(2))
        #expect(m.state == .capturing(.hotkey))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "and eggs"))
        #expect(out.contains(.submitContinuation("add milk and eggs")))
    }

    /// Review H3, and the reason the continuation window exists (64 of 108
    /// cut-offs): "…remind me tomorrow." — decided — "uhh… and also call
    /// Dan". The first real word comes more than a second after the onset.
    /// Going on with your own turn must not have to beat a word window.
    @Test func uhhAndAlsoStillJoinsTheTurn() {
        var m = machine()
        toThinking(&m, text: "remind me tomorrow")
        _ = m.handle(.speechStarted)                     // "uhh…"
        let window = m.handle(.timer(.bargeInHold))      // 1 s, no word yet
        #expect(!window.contains(.onsetRejected(.noWords)))
        #expect(window.contains(.armTimer(.bargeInHold, seconds: 1.0)))
        _ = m.handle(.timer(.bargeInHold))               // 2 s, still "uhh"
        _ = m.handle(.wordsHeard(2))                     // "and also"
        #expect(m.state == .capturing(.hotkey))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "and also call Dan"))
        #expect(out.contains(.submitContinuation("remind me tomorrow and also call Dan")))
    }

    /// …and a filler alone is the person talking: it takes the window, and
    /// the accurate read decides what it was.
    @Test func aFillerIsEnoughToGoOnWithYourOwnTurn() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsGrew)                         // "uhh" written down
        #expect(m.state == .capturing(.hotkey))
    }

    /// Once the sound has stopped with no token at all, the window closes.
    @Test func theContinuationWindowClosesWhenTheSoundStops() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechStarted)
        _ = m.handle(.speechEnded)
        #expect(m.handle(.timer(.bargeInHold)).contains(.onsetRejected(.noWords)))
        #expect(m.state == .thinking(.hotkey))
    }

    /// A filler over the reply is not an interruption (only continuation
    /// takes any token).
    @Test func aFillerOverTheReplyInterruptsNothing() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        #expect(!m.handle(.wordsGrew).contains(.judgeBargeIn))
    }

    /// Review M2: a tap on the key while a noise has the reply ducked pauses
    /// the reply; it used to abandon it.
    @Test func aTapDuringANoiseDuckPausesRatherThanDestroys() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.speechStarted)                     // a fan ducks it
        let down = m.handle(.holdDown)
        #expect(down.contains(.stopSpeaking))
        #expect(!down.contains(.abandonReply))
        let up = m.handle(.holdCancelled)
        #expect(!up.contains(.abandonReply))
        #expect(m.state == .speaking(.hotkey))
        _ = m.handle(.holdDown)
        #expect(m.handle(.holdCancelled).contains(.resumeReply))
    }

    /// Review M6: the judge answers after the audio ran out and the brain is
    /// still writing — the words are still an interruption, not dropped.
    @Test func aLateVerdictOverAParkedReplyStillTakesTheWords() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(2))                     // judging…
        _ = m.handle(.ttsDrained)                        // audio ran out, brain writing
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.bargeInJudged(true))
        #expect(m.state == .capturing(.followUp))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "wait, stop"))
        #expect(out.contains(.abandonReply))
    }

    /// Review M3: where the person has the floor, "yes" is an answer.
    @Test func aYesIsAWordWhereItIsAnAnswer() {
        #expect(TurnPolicy.meaningfulWords(in: "Yes.", countNods: true) == 1)
        #expect(TurnPolicy.meaningfulWords(in: "okay sure", countNods: true) == 2)
        #expect(TurnPolicy.meaningfulWords(in: "uh", countNods: true) == 0)
        #expect(TurnPolicy.meaningfulWords(in: "a", countNods: true) == 0)
        #expect(TurnPolicy.meaningfulWords(in: "no") == 1)          // never a nod
        var m = machine(bargeIn: true)
        #expect(m.wordsCountNods)                     // off: the person's floor
        toThinking(&m)
        #expect(m.wordsCountNods)                     // the person may go on with their turn
        _ = m.handle(.speechQueued)
        #expect(!m.wordsCountNods)                    // over the reply
        var n = machine()
        _ = n.handle(.toggle)
        _ = n.handle(.speechStarted)
        #expect(n.wordsCountNods)                     // capturing
    }

    @Test func aNodWhileMoeThinksIsNotWords() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechStarted)
        // The host reports only meaningful words; zero never takes the floor.
        _ = m.handle(.wordsHeard(0))
        #expect(m.state == .thinking(.hotkey))
    }

    @Test func aSoundWhileTheFirstHalfIsReadBackDoesNotReopenTheTurn() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.speechStarted)           // a chair
        let out = m.handle(.transcribed(turn: turn, "what time is it"))
        #expect(out.contains(.submit("what time is it")))
        #expect(m.state == .thinking(.hotkey))
    }

    @Test func wordsWhileTheFirstHalfIsReadBackStillJoinIt() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))
        let out = m.handle(.transcribed(turn: turn, "sitting in my backyard"))
        #expect(!out.contains { if case .submit = $0 { return true }; return false })
        #expect(m.state == .capturing(.hotkey))
    }

    // MARK: Speaking

    @Test func aSoundOverTheReplyDucksAndComesBackUp() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        let out = m.handle(.speechStarted)
        // Listened to, not ducked: a sound is not yet a voice (2026-09-23).
        #expect(!out.contains(.duckSpeech(true)))
        #expect(out.contains(.asr(true)))       // listening for words
        #expect(out.contains(.resetAsr))
        #expect(!out.contains(.pauseSpeech))
        #expect(!out.contains(.judgeBargeIn))
        // A VAD end does not decide it — the word is often decoded after.
        let ended = m.handle(.speechEnded)
        #expect(!ended.contains(.duckSpeech(false)))
        let closed = m.handle(.timer(.bargeInHold))
        #expect(!closed.contains(.duckSpeech(false)))
        #expect(!closed.contains(.pauseSpeech))
        #expect(!closed.contains(.judgeBargeIn))
        #expect(m.state == .speaking(.hotkey))
        // It spent nothing: the person can still interrupt.
        _ = m.handle(.speechStarted)
        #expect(m.handle(.wordsHeard(2)).contains(.judgeBargeIn))
    }

    /// The old gate: a 300 ms host timer cancelled only by a VAD end that
    /// cannot arrive in under 512 ms, then 0.35 s and a loudness judge. Any
    /// noise lasting half a second reached the judge. Now the judge is not
    /// even asked without words, however long the sound lasts.
    @Test func noLengthOfSoundReachesTheJudgeWithoutWords() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        var all: [M.Action] = []
        for _ in 0..<20 { all += m.handle(.speechStarted) }      // a flapping fan
        all += m.handle(.timer(.bargeInHold))
        #expect(!all.contains(.judgeBargeIn))
        #expect(!all.contains(.pauseSpeech))
    }

    @Test func wordsOverTheReplyAreJudgedThenPauseIt() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        let words = m.handle(.wordsHeard(2))
        #expect(words.contains(.judgeBargeIn))
        #expect(words.contains(.cancelTimer(.bargeInHold)))
        // The window closing while the judge is out changes nothing.
        #expect(m.handle(.timer(.bargeInHold)) == [])
        let out = m.handle(.bargeInJudged(true))
        #expect(out.contains(.pauseSpeech))
        #expect(!out.contains(.resetAsr))      // the words so far are the start of the turn
        #expect(m.state == .capturing(.followUp))
    }

    @Test func theReplyEndingUnderTheWindowHandsTheWordsToTheWindow() {
        var m = machine(bargeIn: true)
        toThinking(&m)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.speechStarted)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        _ = m.handle(.wordsHeard(2))
        #expect(m.state == .capturing(.followUp))
        // …as a plain turn, not an interruption of a reply that is over.
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, ""))
        #expect(!out.contains(.resumeReply))
        #expect(m.state == .followUp)
    }

    @Test func withBargeInOffASoundOverTheReplyDoesNothing() {
        var m = machine()
        toThinking(&m)
        _ = m.handle(.speechQueued)
        #expect(m.handle(.speechStarted) == [.ignoredInterruptionsOff(byName: false)])   // the log line, nothing else
        #expect(m.handle(.wordsHeard(3)) == [])
        #expect(m.state == .speaking(.hotkey))
    }
}
