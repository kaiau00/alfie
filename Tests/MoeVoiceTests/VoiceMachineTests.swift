import Foundation
import Testing
@testable import MoeVoice

struct VoiceMachineTests {

    typealias M = VoiceMachine
    typealias A = M.Action

    private func machine(wake: Bool = false, conversation: Bool = false,
                         holdOpens: Bool = false, bargeIn: Bool = false) -> M {
        var m = M()
        m.tuning.conversation = conversation
        m.tuning.holdOpensConversation = holdOpens
        m.tuning.bargeIn = bargeIn
        _ = m.handle(.setWake(wake))
        return m
    }

    /// Drive a machine through a full spoken turn up to the brain.
    @discardableResult
    private func speakTurn(_ m: inout M, open: M.Event, text: String = "what time is it") -> [A] {
        var out = m.handle(open)
        out += m.handle(.speechStarted)
        out += m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return out }
        out += m.handle(.transcribed(turn: turn, text))
        return out
    }

    // MARK: Resting states

    @Test func wakeSettingMovesBetweenOffAndStandby() {
        var m = M()
        #expect(m.state == .off)
        let on = m.handle(.setWake(true))
        #expect(m.state == .standby)
        #expect(on.contains(.audio(true)))
        #expect(on.contains(.asr(true)))
        let off = m.handle(.setWake(false))
        #expect(m.state == .off)
        #expect(off.contains(.audio(false)))
        #expect(off.contains(.asr(false)))
    }

    @Test func withAHeadStandbyTranscribesNothing() {
        var m = M()
        _ = m.handle(.setWakeHead(true))
        let on = m.handle(.setWake(true))
        #expect(m.state == .standby)
        #expect(on.contains(.audio(true)))
        #expect(on.contains(.wake(true)))
        #expect(!on.contains(.asr(true)))
        let off = m.handle(.setWake(false))
        #expect(off.contains(.wake(false)))
        #expect(off.contains(.audio(false)))
    }

    @Test func aHeadThatLoadsLaterTakesOverStandby() {
        var m = machine(wake: true)
        let out = m.handle(.setWakeHead(true))
        #expect(out.contains(.asr(false)))
        #expect(out.contains(.wake(true)))
        #expect(m.state == .standby)
    }

    @Test func theHeadListensWhileMoeSpeaksAndNotInside() {
        var m = M()
        m.tuning.bargeIn = true      // off, the name is ignored too (InterruptionsOffTests)
        _ = m.handle(.setWakeHead(true))
        _ = m.handle(.setWake(true))
        let woke = m.handle(.woke)
        #expect(woke.contains(.wake(false)))
        #expect(woke.contains(.resetAsr))          // the recogniser was off; its state is stale
        #expect(woke.contains(.asr(true)))
        #expect(m.state == .capturing(.wake))
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("x"))
        _ = m.handle(.transcribed(turn: 1, "what time is it"))
        let speaking = m.handle(.speechQueued)
        #expect(speaking.contains(.wake(true)))
        #expect(m.state == .speaking(.wake))
        // The name over Moe's voice: stop, cut, listen.
        let again = m.handle(.woke)
        #expect(again.contains(.stopSpeaking))
        #expect(again.contains(.abandonReply))
        #expect(m.state == .capturing(.wake))
    }

    @Test func theNameDuringABargeInReadBackIsATurnNotAResume() {
        // Barge-in on: the VAD pauses Moe first, then the head hears that
        // the interruption was the name. It must not be treated as a
        // false interruption ("Hey Moe" strips to nothing → resume).
        var m = M()
        _ = m.handle(.setWakeHead(true))
        _ = m.handle(.setWake(true))
        m.tuning.bargeIn = true
        _ = m.handle(.woke)
        _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("x"))
        _ = m.handle(.transcribed(turn: 1, "what time is it"))
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.wake))
        interrupt(&m)                                // the gate fired: paused
        #expect(m.state == .capturing(.followUp))
        let woke = m.handle(.woke)
        #expect(woke.contains(.abandonReply))
        #expect(woke.contains(.cue(.wake)))
        #expect(m.state == .capturing(.wake))
        _ = m.handle(.speechEnded); _ = m.handle(.endOfUtterance("x"))
        let empty = m.handle(.transcribed(turn: 2, ""))
        #expect(!empty.contains(.resumeReply))
        #expect(m.state == .attending(.wake))
    }

    @Test func theNameInsideAFollowUpCaptureMakesItAWakeTurn() {
        var m = M()
        _ = m.handle(.setWakeHead(true))
        _ = m.handle(.setWake(true))
        m.tuning.conversation = true
        _ = m.handle(.woke)
        _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("x"))
        _ = m.handle(.transcribed(turn: 1, "what time is it"))
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        _ = m.handle(.speechStarted)                 // "hmm, hey moe, …": the VAD first
        #expect(m.state == .capturing(.followUp))
        let woke = m.handle(.woke)
        #expect(woke.contains(.cue(.wake)))
        #expect(m.state == .capturing(.wake))         // the re-read is cut at the name
        #expect(!woke.contains(.stopSpeaking))
    }

    @Test func thanksMoeClosesTheWindowQuietly() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("x"))
        #expect(m.state == .deciding(.followUp, turn: 2))
        let out = m.handle(.dismiss)             // the re-read was "thanks moe"
        #expect(out.contains(.cue(.close)))
        #expect(out.contains(.conversationEnded))
        #expect(m.state == .off)
        #expect(!m.inConversation)
        // Over a reply it is nobody's business here (a barge-in decides).
        var n = machine(conversation: true)
        speakTurn(&n, open: .toggle)
        _ = n.handle(.speechQueued)
        #expect(n.handle(.dismiss) == [])
        #expect(n.state == .speaking(.hotkey))
    }

    @Test func theKeyInterruptsAThoughtInProgress() {
        // Pressing the hotkey while Moe is working on the last question
        // withdraws it and takes the floor. Waiting for an answer you no
        // longer want, unable to say so, is the complaint this fixes.
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        #expect(m.state == .thinking(.hotkey))
        let out = m.handle(.toggle)
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.resetAsr))
        #expect(m.state == .attending(.hotkey))
        // And while the words are still being read back.
        var n = machine(conversation: true)
        _ = n.handle(.toggle); _ = n.handle(.speechStarted); _ = n.handle(.endOfUtterance("x"))
        #expect(n.state == .deciding(.hotkey, turn: 1))
        _ = n.handle(.toggle)
        #expect(n.state == .attending(.hotkey))
        // The stale read, when it lands, is nobody's.
        let stale = n.handle(.transcribed(turn: 1, "what time is it"))
        #expect(!stale.contains(.submit("what time is it")))
    }

    @Test func talkingWhileMoeThinksGoesOnWithTheTurn() {
        // Nothing has been heard yet, so a voice now is not a reaction to
        // the reply: it is the same turn going on. The half-answer is
        // withdrawn and both halves go as one request — with or without
        // barge-in, because nothing is playing to barge into.
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.speechStarted)
        #expect(m.state == .thinking(.hotkey))      // a sound is not yet a voice
        _ = m.handle(.wordsHeard(2))
        #expect(m.state == .capturing(.hotkey))
        _ = m.handle(.endOfUtterance("x"))
        let out = m.handle(.transcribed(turn: 2, "actually what about friday"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submitContinuation("what time is it actually what about friday")))
        // A cough leaves the question alone.
        var n = machine(conversation: true, bargeIn: true)
        speakTurn(&n, open: .toggle)
        _ = n.handle(.speechStarted); _ = n.handle(.wordsHeard(1)); _ = n.handle(.endOfUtterance(""))
        let cough = n.handle(.transcribed(turn: 2, ""))
        #expect(cough.contains(.resumeReply))
        #expect(n.state == .thinking(.hotkey))
    }

    @Test func aQuietWindowIsOfferedAnEndingBeforeItTimesOut() {
        var m = machine(conversation: true)
        m.tuning.followUpSeconds = 8
        m.tuning.offerToCloseAfter = 4
        speakTurn(&m, open: .toggle)
        let done = m.handle(.speechQueued) + m.handle(.brainFinished) + m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        #expect(done.contains(.armTimer(.offerToClose, seconds: 4)))
        #expect(done.contains(.armTimer(.followUp, seconds: 8)))
        // Four seconds of nothing: Moe asks, and keeps listening.
        let offer = m.handle(.timer(.offerToClose))
        #expect(offer.contains(.offerToClose))
        #expect(m.state == .followUp)
        // Still nothing: the window closes as it always would have.
        let close = m.handle(.timer(.followUp))
        #expect(close.contains(.cue(.close)))
        #expect(m.state == .off)
    }

    /// A TV or a room of voices in the follow-up window: each capture that
    /// comes to nothing gets a short extension, not a fresh 8 s, and the
    /// third in a row closes the window. 18 windows from 09-23 to 09-29
    /// stayed open a median 13.5 s and up to 60 s this way.
    @Test func noiseInTheWindowShortensItAndThenClosesIt() {
        var m = machine(conversation: true)
        m.tuning.followUpSeconds = 8
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        func noise(_ m: inout M) -> [A] {
            var out = m.handle(.speechStarted)
            out += m.handle(.endOfUtterance("…"))
            guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return out }
            out += m.handle(.transcribed(turn: turn, ""))
            return out
        }
        let first = noise(&m)
        #expect(m.state == .followUp)
        #expect(first.contains(.armTimer(.followUp, seconds: 4)))
        #expect(!first.contains(.armTimer(.followUp, seconds: 8)), "a fresh 8 s after every noise was the bug")
        let second = noise(&m)
        #expect(m.state == .followUp)
        #expect(second.contains(.armTimer(.followUp, seconds: 4)))
        let third = noise(&m)
        #expect(third.contains(.cue(.close)))
        #expect(m.state != .followUp)
    }

    @Test func aRealFollowUpStartsTheCountAgain() {
        var m = machine(conversation: true)
        m.tuning.followUpSeconds = 8
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        for _ in 0..<2 {
            _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
            if case .deciding(_, let turn) = m.state { _ = m.handle(.transcribed(turn: turn, "")) }
        }
        #expect(m.state == .followUp)
        // They answer: the next reply's window is a whole one again.
        _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding"); return }
        _ = m.handle(.transcribed(turn: turn, "and the weekend"))
        let done = m.handle(.speechQueued) + m.handle(.brainFinished) + m.handle(.ttsDrained)
        #expect(done.contains(.armTimer(.followUp, seconds: 8)))
        _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let t2) = m.state else { Issue.record("not deciding"); return }
        let after = m.handle(.transcribed(turn: t2, ""))
        #expect(m.state == .followUp, "one noise after a fresh reply is the first, not the third")
        #expect(after.contains(.armTimer(.followUp, seconds: 4)))
    }

    @Test func theOfferIsNotMadeWhenItWouldNeverBeHeard() {
        // Off by configuration, and never past the window's own end.
        var off = machine(conversation: true)
        off.tuning.offerToCloseAfter = 0
        speakTurn(&off, open: .toggle)
        let a = off.handle(.speechQueued) + off.handle(.brainFinished) + off.handle(.ttsDrained)
        #expect(!a.contains { if case .armTimer(.offerToClose, _) = $0 { return true } else { return false } })
        var late = machine(conversation: true)
        late.tuning.followUpSeconds = 8
        late.tuning.offerToCloseAfter = 9
        speakTurn(&late, open: .toggle)
        let b = late.handle(.speechQueued) + late.handle(.brainFinished) + late.handle(.ttsDrained)
        #expect(!b.contains { if case .armTimer(.offerToClose, _) = $0 { return true } else { return false } })
    }

    @Test func talkingCancelsTheOffersTimer() {
        var m = machine(conversation: true)
        m.tuning.offerToCloseAfter = 4
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        let spoke = m.handle(.speechStarted)
        #expect(spoke.contains(.cancelTimer(.offerToClose)))
        #expect(m.state == .capturing(.followUp))
    }

    @Test func theEndpointerDoesNotCutAnUnfinishedSentence() {
        // Measured: the endpointer fired on "…and say that we have to" and
        // Moe answered half a sentence with "go ahead, I'm listening".
        var m = machine()
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        let mid = m.handle(.endOfUtterance("update that note and say that we have to"))
        #expect(m.state == .capturing(.hotkey))
        #expect(mid.contains(.armTimer(.silence, seconds: m.tuning.incompleteSilenceSeconds)))
        #expect(!mid.contains { if case .transcribe = $0 { return true } else { return false } })
        // The rest of the sentence ends it as usual.
        let done = m.handle(.endOfUtterance("update that note and say that we have to leave by five"))
        #expect(done.contains(.transcribe(turn: 1)))
        // And a pause that really is the end still ends it.
        var n = machine()
        _ = n.handle(.toggle); _ = n.handle(.speechStarted)
        _ = n.handle(.endOfUtterance("remind me at five and"))
        #expect(n.state == .capturing(.hotkey))
        let silence = n.handle(.timer(.silence))
        #expect(silence.contains(.transcribe(turn: 1)))
    }

    @Test func theHeadIsOffWithoutTheWakeSwitch() {
        var m = M()
        _ = m.handle(.setWakeHead(true))
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 1, "hi"))
        let speaking = m.handle(.speechQueued)
        #expect(!speaking.contains(.wake(true)))
    }

    @Test func standbyNeverCaptures() {
        let m = machine(wake: true)
        #expect(m.state == .standby)
        #expect(!m.inConversation)
    }

    // MARK: Hold to talk

    @Test func holdIsCapturedAndTranscribedOnRelease() {
        var m = machine()
        let down = m.handle(.holdDown)
        #expect(m.state == .capturing(.hold))
        #expect(down.contains(.capture(true)))
        #expect(down.contains(.audio(true)))
        #expect(down.contains(.resetAsr))
        // The endpointer has no say while the key is down.
        #expect(m.handle(.endOfUtterance("half a")) == [])
        #expect(m.state == .capturing(.hold))
        let up = m.handle(.holdUp)
        #expect(up.contains(.transcribe(turn: 1)))
        #expect(up.contains(.capture(false)))
        #expect(up.contains(.asr(false)))
        if case .deciding(.hold, 1) = m.state {} else { Issue.record("\(m.state)") }
    }

    @Test func emptyHoldClosesWithoutAsking() {
        var m = machine()
        _ = m.handle(.holdDown)
        _ = m.handle(.holdUp)
        let out = m.handle(.transcribed(turn: 1, "   "))
        #expect(m.state == .off)
        #expect(!out.contains { if case .submit = $0 { return true } else { return false } })
        #expect(out.contains(.conversationEnded))
        #expect(out.contains(.audio(false)))
    }

    @Test func heldTurnSubmitsAndDoesNotReopenByDefault() {
        var m2 = machine()
        _ = m2.handle(.holdDown)
        _ = m2.handle(.holdUp)
        let sub = m2.handle(.transcribed(turn: 1, "hello"))
        #expect(sub.contains(.submit("hello")))
        #expect(m2.state == .thinking(.hold))
        _ = m2.handle(.speechQueued)
        #expect(m2.state == .speaking(.hold))
        _ = m2.handle(.brainFinished)
        #expect(m2.state == .speaking(.hold))      // audio still playing
        let done = m2.handle(.ttsDrained)
        #expect(m2.state == .off)
        #expect(done.contains(.conversationEnded))
    }

    @Test func heldTurnCanOpenAWindowWhenAsked() {
        var m = machine(holdOpens: true)
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 1, "hello"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        let done = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        #expect(done.contains(.armTimer(.followUp, seconds: 8)))
        #expect(m.inConversation)
    }

    @Test func releaseDuringLoadingIsIgnoredByTheMachine() {
        // The host only sends holdDown once the models are up; a stray
        // holdUp before that must do nothing at all.
        var m = machine()
        #expect(m.handle(.holdUp) == [])
        #expect(m.state == .off)
    }

    // MARK: The hotkey

    @Test func hotkeyOpensAndTheEndpointerEndsTheTurn() {
        var m = machine()
        let open = m.handle(.toggle)
        #expect(m.state == .attending(.hotkey))
        #expect(open.contains(.armTimer(.attend, seconds: 8)))
        #expect(open.contains(.capture(true)))   // from the first syllable
        let started = m.handle(.speechStarted)
        #expect(started.contains(.cancelTimer(.attend)))
        #expect(m.state == .capturing(.hotkey))
        let eou = m.handle(.endOfUtterance("what time"))
        #expect(eou.contains(.transcribe(turn: 1)))
    }

    @Test func hotkeyAgainWhileWaitingCloses() {
        var m = machine(wake: true)
        _ = m.handle(.toggle)
        let out = m.handle(.toggle)
        #expect(m.state == .standby)
        #expect(out.contains(.cancelTimer(.attend)))
        #expect(out.contains(.conversationEnded))
    }

    @Test func hotkeyWhileCapturingEndsTheTurnNow() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted)
        let out = m.handle(.toggle)
        #expect(out.contains(.transcribe(turn: 1)))
    }

    @Test func hotkeyWhileSpeakingInterruptsAndListens() {
        var m = machine()
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        let out = m.handle(.toggle)
        #expect(out.contains(.stopSpeaking))
        #expect(out.contains(.abandonReply))
        #expect(m.state == .attending(.hotkey))
        // The abandoned brain finishing later changes nothing.
        #expect(m.handle(.brainFinished) == [])
        #expect(m.state == .attending(.hotkey))
    }

    @Test func attendTimeoutClosesQuietly() {
        var m = machine(wake: true)
        _ = m.handle(.toggle)
        let out = m.handle(.timer(.attend))
        #expect(m.state == .standby)
        #expect(out.contains(.conversationEnded))
        #expect(!out.contains(.cue(.close)))
    }

    @Test func endOfUtteranceWithoutVadStillCountsWhileAttending() {
        var m = machine()
        _ = m.handle(.toggle)
        let out = m.handle(.endOfUtterance("turn on the lights"))
        #expect(out.contains(.transcribe(turn: 1)))
        #expect(out.contains(.cancelTimer(.attend)))
    }

    @Test func emptyEndOfUtteranceWhileAttendingIsNoise() {
        var m = machine()
        _ = m.handle(.toggle)
        #expect(m.handle(.endOfUtterance("  ")) == [])
        #expect(m.state == .attending(.hotkey))
    }

    // MARK: The wake word

    @Test func wakeGoesStraightToCapturingWithACue() {
        var m = machine(wake: true)
        let out = m.handle(.woke)
        #expect(m.state == .capturing(.wake))
        #expect(out.contains(.cue(.wake)))
        #expect(out.contains(.capture(true)))
        #expect(!out.contains(.resetAsr))   // the request is in the same breath
        #expect(m.inConversation)
    }

    @Test func nameAloneWaitsForTheRequest() {
        var m = machine(wake: true)
        _ = m.handle(.woke)
        _ = m.handle(.endOfUtterance("hey moe"))
        let out = m.handle(.transcribed(turn: 1, ""))
        #expect(m.state == .attending(.wake))
        #expect(out.contains(.armTimer(.attend, seconds: 8)))
    }

    // The name is not the request. A wake capture opens with "Hey Moe"
    // still sounding, so the first speech end and the first empty endpoint
    // after it are the name's, not a request's. Measured 2026-09-06 before
    // these existed: 36 of 40 wake turns were decided about a second after
    // the name, on a turn-model verdict about "Hey Moe." (p 0.92–0.99).

    @Test func theNamesOwnEndingDoesNotStartTheShortSilenceClock() {
        var m = machine(wake: true)
        let woke = m.handle(.woke)
        #expect(woke.contains(.armTimer(.silence, seconds: 4)))   // waiting for the request
        let out = m.handle(.speechEnded)
        #expect(!out.contains(.armTimer(.silence, seconds: 1.5)))
        #expect(m.state == .capturing(.wake))
    }

    @Test func anEmptyEndpointBeforeTheRequestIsNotAnUtterance() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        let out = m.handle(.endOfUtterance(""))
        #expect(!out.contains(.askTurnModel))
        #expect(!out.contains(.armTimer(.silence, seconds: 1.5)))
        #expect(out.contains(.resetAsr))
        #expect(m.state == .capturing(.wake))
    }

    @Test func theRequestAfterTheNameEndsTheTurnAsBefore() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        _ = m.handle(.speechEnded)                       // the name
        _ = m.handle(.speechStarted)                     // the request
        #expect(m.handle(.speechEnded).contains(.armTimer(.silence, seconds: 1.5)))
        #expect(m.handle(.endOfUtterance("what time is it")).contains(.askTurnModel))
    }

    @Test func wordsFromTheEndpointerCountAsTheRequestEvenWithoutAVadEdge() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        #expect(m.handle(.endOfUtterance("what time is it")).contains(.askTurnModel))
    }

    @Test func aBlipAfterTheNamePutsTheCaptureBackOnTheNoSpeechClock() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        _ = m.handle(.speechEnded)                       // the name
        _ = m.handle(.speechStarted)                     // a breath
        let out = m.handle(.speechWasNoise)
        #expect(out.contains(.armTimer(.silence, seconds: 4)))
        #expect(m.state == .capturing(.wake))
        // Back to waiting: the blip's ending starts no short clock and an
        // empty endpoint is still nothing.
        #expect(!m.handle(.speechEnded).contains(.armTimer(.silence, seconds: 1.5)))
        #expect(!m.handle(.endOfUtterance("")).contains(.askTurnModel))
        // The request, when it comes, is a request.
        _ = m.handle(.speechStarted)
        #expect(m.handle(.speechEnded).contains(.armTimer(.silence, seconds: 1.5)))
    }

    @Test func noiseIsOnlyNoiseBeforeTheRequest() {
        var m = machine(wake: true)
        _ = m.handle(.woke)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("what time"))        // words: the request is under way
        #expect(m.handle(.speechWasNoise) == [])
        var h = machine()
        _ = h.handle(.holdDown)
        #expect(h.handle(.speechWasNoise) == [])
    }

    // A fast talker with no pause the VAD can see: the endpointer proposes an
    // ending on an unfinished clause and the 3 s clock must not fire while
    // words are still coming. Measured 2026-09-06 21:57Z: it did, at 27 s,
    // thirteen words into the next clause.

    @Test func wordsStillArrivingRestartTheUnfinishedSentenceClock() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        _ = m.handle(.speechStarted)
        let eou = m.handle(.endOfUtterance("and all these different stuff like that"))
        #expect(eou.contains(.armTimer(.silence, seconds: 3)))
        #expect(!eou.contains(.askTurnModel))
        // More words: the clock starts again from now, and nothing ends.
        let more = m.handle(.wordsGrew)
        #expect(more.contains(.armTimer(.silence, seconds: 3)))
        #expect(m.state == .capturing(.wake))
        // A finished ending afterwards goes to the turn model as usual and
        // the clock is no longer the unfinished one.
        let done = m.handle(.endOfUtterance("go do something"))
        #expect(done.contains(.askTurnModel))
        #expect(!m.handle(.wordsGrew).contains { if case .armTimer(.silence, _) = $0 { return true }; return false })
    }

    @Test func wordsGrowingWithoutTheClockChangesNothing() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        _ = m.handle(.speechStarted)
        #expect(m.handle(.wordsGrew) == [])
        var h = machine()
        _ = h.handle(.holdDown)
        _ = h.handle(.endOfUtterance("and then"))
        #expect(h.handle(.wordsGrew) == [])          // the key decides a hold
    }

    @Test func wordsWhileAttendingBecomeACaptureAndGetTheSameGates() {
        var m = machine(wake: true)
        m.tuning.turnModel = true
        _ = m.handle(.woke)
        _ = m.handle(.speechStarted); _ = m.handle(.speechEnded)
        _ = m.handle(.endOfUtterance("hey moe"))
        _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, ""))
        #expect(m.state == .attending(.wake))
        // The endpointer proposes an ending on a dangler: not the end.
        let out = m.handle(.endOfUtterance("i'm on a cloud code session so ready to prompt i wanna"))
        #expect(m.state == .capturing(.wake))
        #expect(out.contains(.armTimer(.silence, seconds: 3)))
        #expect(!out.contains(.askTurnModel))
        // A finished-sounding ending goes to the turn model, not straight to deciding.
        let done = m.handle(.endOfUtterance("build me a landing page"))
        #expect(done.contains(.askTurnModel))
        #expect(m.state == .capturing(.wake))
    }

    @Test func aHoldIsNeverWaitingForTheName() {
        var m = machine()
        _ = m.handle(.holdDown)
        // The key decides a hold; the endpointer's empty read is ignored
        // there for its own reason and nothing here changes that.
        #expect(m.handle(.endOfUtterance("")) == [])
        #expect(m.state == .capturing(.hold))
    }

    @Test func wakeTurnReturnsToStandbyWithoutConversationMode() {
        var m = machine(wake: true)
        speakTurn(&m, open: .woke)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .standby)
    }

    @Test func wakeIsIgnoredWhileOff() {
        var m = machine()
        #expect(m.handle(.woke) == [])
        #expect(m.state == .off)
    }

    /// The owner, 2026-09-25: with Interrupt off nothing said over Moe
    /// stopped it, the name included. Reversed 2026-10-06 for the name only:
    /// five wakes over a reply were ignored 09-29 → 09-30, two ending on the
    /// hotkey. On or off, the name stops the reply now; the host feeds only
    /// a sure wake (`WakeOwnerCheck.stopsReplyAtHead`).
    @Test func theNameStopsTheReplyWithBargeInOff() {
        var m = machine(wake: true)
        speakTurn(&m, open: .woke)
        _ = m.handle(.speechQueued)
        let out = m.handle(.woke)
        #expect(out.contains(.stopSpeaking))
        #expect(out.contains(.abandonReply))
        #expect(m.state == .capturing(.wake))
        var on = machine(wake: true, bargeIn: true)
        speakTurn(&on, open: .woke)
        _ = on.handle(.speechQueued)
        let stopped = on.handle(.woke)
        #expect(stopped.contains(.stopSpeaking))
        #expect(stopped.contains(.abandonReply))
        #expect(on.state == .capturing(.wake))
    }

    // MARK: Follow-up window — the clock starts when the audio ends

    @Test func followUpOpensOnlyWhenTheLastBufferWasHeard() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        let brainDone = m.handle(.brainFinished)
        #expect(m.state == .speaking(.hotkey))
        #expect(!brainDone.contains { if case .armTimer(.followUp, _) = $0 { return true } else { return false } })
        let heard = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        #expect(heard.contains(.armTimer(.followUp, seconds: 8)))
        #expect(heard.contains(.resetAsr))
    }

    @Test func drainedBeforeTheBrainIsDoneParksInThinking() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
    }

    @Test func unspokenReplyOpensTheWindowWhenTheBrainFinishes() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        let out = m.handle(.brainFinished)     // speakReplies off: nothing queued
        #expect(m.state == .followUp)
        #expect(out.contains(.armTimer(.followUp, seconds: 8)))
    }

    @Test func speakingInTheWindowIsANewTurnWithoutTheName() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        let out = m.handle(.speechStarted)
        #expect(out.contains(.cancelTimer(.followUp)))
        #expect(m.state == .capturing(.followUp))
        _ = m.handle(.endOfUtterance("and tomorrow"))
        if case .deciding(.followUp, 2) = m.state {} else { Issue.record("\(m.state)") }
        _ = m.handle(.transcribed(turn: 2, "and tomorrow"))
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)          // the window stays a window
    }

    @Test func windowTimeoutClosesWithACue() {
        var m = machine(wake: true, conversation: true)
        speakTurn(&m, open: .woke)
        _ = m.handle(.brainFinished)
        let out = m.handle(.timer(.followUp))
        #expect(m.state == .standby)
        #expect(out.contains(.cue(.close)))
        #expect(out.contains(.conversationEnded))
    }

    @Test func aHeldTurnInsideAWindowKeepsTheWindow() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.brainFinished)
        #expect(m.state == .followUp)
        let down = m.handle(.holdDown)
        #expect(down.contains(.cancelTimer(.followUp)))
        _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 2, "more"))
        _ = m.handle(.brainFinished)
        #expect(m.state == .followUp)
    }

    @Test func emptyFollowUpTurnReopensTheWindow() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.brainFinished)
        _ = m.handle(.speechStarted)
        // "um" alone is not a finished thought, so the endpointer's token
        // no longer ends the turn; the pause after it does.
        _ = m.handle(.endOfUtterance("um"))
        _ = m.handle(.timer(.silence))
        let out = m.handle(.transcribed(turn: 2, ""))
        #expect(m.state == .followUp)
        // A few more seconds, not a fresh window: a capture that came to
        // nothing is not the person answering (`noiseInTheWindowShortensItAndThenClosesIt`).
        #expect(out.contains(.armTimer(.followUp, seconds: 4)))
    }

    // MARK: Barge-in

    /// Speech over a reply, held long enough and judged to be the person.
    /// Two steps, because the first no longer stops anything: the reply is
    /// ducked while Moe works out whose voice it is.
    private func interrupt(_ m: inout VoiceMachine) {
        // Sound ducks the reply; words are what get it judged.
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(2))
        _ = m.handle(.bargeInJudged(true))
    }

    @Test func bargeInIsOffByDefault() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        // Nothing but the log line saying so (InterruptionsOffTests).
        #expect(m.handle(.speechStarted) == [.ignoredInterruptionsOff(byName: false)])
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func speechOverAReplyDucksItRatherThanStoppingIt() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        let out = m.handle(.speechStarted)
        // The whole point: at this instant nothing is known but that a
        // sound was speech-shaped, so nothing is stopped — and nothing is
        // ducked either, until a word says it was a voice (2026-09-23: bare
        // onsets over replies pumped the volume).
        #expect(!out.contains(.stopSpeaking))
        #expect(!out.contains(.duckSpeech(true)))
        #expect(out.contains(.asr(true)))
        #expect(out.contains(.armTimer(.bargeInHold, seconds: 1.0)))
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func aVoiceThatHoldsAndIsJudgedTheirsPausesTheReply() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        #expect(!m.handle(.speechEnded).contains(.judgeBargeIn))   // sound alone is never judged
        #expect(m.handle(.wordsHeard(2)).contains(.judgeBargeIn))
        let out = m.handle(.bargeInJudged(true))
        // Paused, not stopped: if the words turn out to be nothing the
        // reply carries on mid-word rather than re-saying its sentence.
        #expect(out.contains(.pauseSpeech))
        #expect(!out.contains(.stopSpeaking))
        #expect(out.contains(.duckSpeech(false)))
        #expect(!out.contains(.abandonReply))      // decided once the words are known
        #expect(m.state == .capturing(.followUp))
    }

    @Test func realWordsAfterAPauseEndTheReplyOutright() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        interrupt(&m)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "no, the other one"))
        #expect(out.contains(.abandonReply))
        #expect(!out.contains(.resumeReply))
    }

    @Test func aCoughWhileThinkingDoesNotSpendTheOnePauseAReplyGets() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        #expect(m.state == .thinking(.hotkey))
        // A cough over the thinking pause: nothing is playing, nothing is
        // stopped, and with no words nothing is even held — the word
        // window closes and Moe goes on thinking.
        _ = m.handle(.speechStarted)
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.speechEnded)                   // a cough is short
        let out = m.handle(.timer(.bargeInHold))
        #expect(!out.contains(.resumeReply))
        #expect(m.state == .thinking(.hotkey))
        // The reply starts. A real interruption of it must still be
        // possible: before this, the cough above had used it up.
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        let over = m.handle(.speechStarted)
        #expect(over.contains(.armTimer(.bargeInHold, seconds: 1.0)))
    }

    @Test func aFalseInterruptionOfTheSpokenReplyStillSpendsIt() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        interrupt(&m)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, ""))
        // Back to where it was — the brain had not finished, so thinking —
        // and the VAD gets no second go at this reply.
        #expect(m.state == .thinking(.hotkey))
        #expect(m.handle(.speechStarted) == [])
    }

    @Test func aVoiceThatIsNotTheirsNeverInterruptsAtAll() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(2))
        let out = m.handle(.bargeInJudged(false))
        // The room, or somebody talking near the person rather than to
        // them. Moe comes back up and carries on; the reply was never
        // stopped, so there is nothing to resume.
        #expect(out.contains(.duckSpeech(false)))
        #expect(!out.contains(.stopSpeaking))
        #expect(!out.contains(.resumeReply))
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func aRoomThatKeepsTrippingTheVadDoesNotSpendTheBargeIn() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        // Three false starts, none of which stops anything.
        for _ in 0..<3 {
            _ = m.handle(.speechStarted)
            _ = m.handle(.wordsHeard(2))
            _ = m.handle(.bargeInJudged(false))
            #expect(m.state == .speaking(.hotkey))
        }
        // And the person can still interrupt. `bargeInSpent` is for a
        // false interruption that actually happened; nothing here did.
        interrupt(&m)
        #expect(m.state == .capturing(.followUp))
    }

    @Test func aBlipWithNoWordsIsForgotten() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.speechEnded)
        let out = m.handle(.timer(.bargeInHold))
        #expect(!out.contains(.duckSpeech(false)))     // it was never ducked
        #expect(out.contains(.asr(false)))
        #expect(!out.contains(.stopSpeaking))
        #expect(!out.contains(.pauseSpeech))
        #expect(m.state == .speaking(.hotkey))
        // …and words arriving late, after the window closed, decide
        // nothing.
        #expect(m.handle(.wordsHeard(3)) == [])
    }

    @Test func theNameOverADuckedReplyStillCutsItStraightAway() {
        var m = machine(wake: true, conversation: true, bargeIn: true)
        m.tuning.wakeHead = true
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))           // ducked, undecided
        let out = m.handle(.woke)
        // Saying its name never waits on a judgement, and the duck must
        // not survive into whatever comes next.
        #expect(out.contains(.stopSpeaking))
        #expect(out.contains(.duckSpeech(false)))
        #expect(m.state == .capturing(.wake))
    }

    @Test func aKeyOverADuckedReplyLetsItGoToo() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))
        let out = m.handle(.toggle)
        #expect(out.contains(.duckSpeech(false)))
        #expect(out.contains(.stopSpeaking))
        // …and a judgement arriving late for a barge-in nobody is waiting
        // on any more changes nothing.
        #expect(m.handle(.bargeInJudged(true)) == [])
    }

    @Test func realWordsAfterABargeInAbandonTheReplyAndAsk() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        interrupt(&m)
        _ = m.handle(.endOfUtterance("no wait"))
        let out = m.handle(.transcribed(turn: 2, "no wait, tomorrow"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submit("no wait, tomorrow")))
        #expect(m.state == .thinking(.hotkey))     // the session it interrupted
    }

    @Test func aCoughAfterABargeInResumesTheReply() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        // Long enough and loud enough to be taken for them, and then
        // nothing usable in it — the case the duck cannot catch.
        interrupt(&m)
        _ = m.handle(.speechEnded)
        _ = m.handle(.timer(.silence))
        let out = m.handle(.transcribed(turn: 2, ""))
        #expect(out.contains(.resumeReply))
        #expect(!out.contains(.abandonReply))
        #expect(m.state == .thinking(.hotkey))     // the brain still owes the rest
        // The host re-queues from the last heard sentence…
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        // …and a late brainFinished for that same reply is not owed twice.
        #expect(m.handle(.brainFinished) == [])
    }

    @Test func aCoughAfterTheBrainFinishedStillResumes() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        interrupt(&m)
        _ = m.handle(.endOfUtterance(""))
        let out = m.handle(.transcribed(turn: 2, ""))
        #expect(out.contains(.resumeReply))
        #expect(m.state == .speaking(.hotkey))     // the remainder is still the reply
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
    }

    /// A 29 ms brush against the held key cut a reply 139 characters in on
    /// 2026-09-04, and the release then logged "a tap — nothing recorded":
    /// the machine knew it was not speech only after the answer was gone.
    /// The sound still stops at once — being talked over is the complaint —
    /// and the reply is never lost when the press was not a turn.
    ///
    /// Since 2026-09-08 the tap is also the pause button, so where this
    /// used to resume on the first tap it now holds and resumes on the
    /// second. `PausingTheReplyTests` is the whole grammar; what matters
    /// here is that a brush still costs nobody an answer.
    @Test func aTapNeverLosesTheReply() {
        var m = machine(wake: true, conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        #expect(m.state == .speaking(.hotkey))

        let down = m.handle(.holdDown)
        #expect(down.contains(.stopSpeaking), "the sound must stop immediately")
        #expect(!down.contains(.abandonReply), "the reply is not gone yet")

        let up = m.handle(.holdCancelled)
        #expect(!up.contains(.abandonReply), "a brush must never destroy an answer")
        #expect(m.state == .speaking(.hotkey), "still the reply, held where it stopped")

        // And it is one tap away from being heard out.
        _ = m.handle(.holdDown)
        let second = m.handle(.holdCancelled)
        #expect(second.contains(.resumeReply))
        #expect(m.state == .speaking(.hotkey), "back to saying the rest of it")
    }

    /// And a press that really was a turn still ends the reply — once the
    /// words arrive, which is when it is known.
    @Test func aRealHoldStillEndsTheReply() {
        var m = machine(wake: true, conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.holdDown)
        _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("expected .deciding, got \(m.state)"); return
        }
        let out = m.handle(.transcribed(turn: turn, "actually do the other thing"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submit("actually do the other thing")))
    }

    @Test func interruptingAFinishedReplyStillCutsIt() {
        // The brain is done, the audio is not: the hotkey, real words and
        // the name all still tell the host to cut the transcript, at once.
        //
        // The *held* key is no longer in this list, and that is deliberate:
        // it is the one press that can turn out not to have been one. See
        // `aTapPutsTheReplyBack` below.
        for interrupt in [M.Event.toggle, .woke] {
            var m = machine(wake: true, conversation: true, bargeIn: true)
            speakTurn(&m, open: .toggle)
            _ = m.handle(.speechQueued)
            _ = m.handle(.brainFinished)
            #expect(m.state == .speaking(.hotkey))
            let out = m.handle(interrupt)
            #expect(out.contains(.stopSpeaking), "\(interrupt)")
            #expect(out.contains(.abandonReply), "\(interrupt)")
        }
        // Real words over a finished reply, via the VAD.
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        interrupt(&m)
        _ = m.handle(.endOfUtterance("x"))
        let out = m.handle(.transcribed(turn: 2, "actually no"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submit("actually no")))
        // A reply heard to its end is nobody's to cut.
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        #expect(!m.handle(.toggle).contains(.abandonReply))
    }

    @Test func aDictationDuringABargeInReadBackKeepsTheInterruptedSession() {
        // Conversation mode off: the reply is abandoned by the dictation,
        // and the interrupting words come back as a plain held-key turn —
        // not under follow-up rules, and an empty one opens no window.
        var m = machine(bargeIn: true)
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 1, "first"))
        _ = m.handle(.speechQueued)
        interrupt(&m)
        _ = m.handle(.endOfUtterance("x"))
        #expect(m.state == .deciding(.followUp, turn: 2))
        #expect(m.handle(.suspend).contains(.abandonReply))
        _ = m.handle(.resume)
        #expect(m.state == .deciding(.hold, turn: 2))
        let empty = m.handle(.transcribed(turn: 2, ""))
        #expect(!empty.contains(.resumeReply))
        #expect(m.state == .off)
        #expect(!m.inConversation)
    }

    @Test func aReplyIsPausedByTheVadOnlyOnce() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        interrupt(&m)
        _ = m.handle(.endOfUtterance(""))
        _ = m.handle(.transcribed(turn: 2, ""))     // false interruption, resumed
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        #expect(m.handle(.speechStarted) == [])     // the room does not get a second go
        #expect(m.state == .speaking(.hotkey))
        // The key still does.
        #expect(m.handle(.holdDown).contains(.stopSpeaking))
    }

    @Test func aDictationOverAnInterruptedReplyAbandonsIt() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        let out = m.handle(.suspend)
        #expect(out.contains(.abandonReply))
        _ = m.handle(.resume)
        // Nothing of the old reply survives: a later empty turn is just empty.
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance(""))
        let later = m.handle(.transcribed(turn: 2, ""))
        #expect(!later.contains(.resumeReply))
    }

    @Test func realWordsAfterABargeInKeepTheSessionsRules() {
        // Conversation mode off: a held turn's reply, interrupted with real
        // words, answers them and then closes — no window appears.
        var m = machine(bargeIn: true)
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 1, "first"))
        _ = m.handle(.speechQueued)
        interrupt(&m)
        _ = m.handle(.endOfUtterance("x"))
        _ = m.handle(.transcribed(turn: 2, "second"))
        #expect(m.state == .thinking(.hold))
        _ = m.handle(.brainFinished)
        #expect(m.state == .off)
    }

    /// The key over a reply a barge-in already paused: the press may be a
    /// tap, so the reply is only dropped once real words replace it
    /// (TapNeverDestroysTests). It used to be dropped on the way down.
    @Test func aKeyDuringAnInterruptedReplyAbandonsItOnlyForWords() {
        var m = machine(conversation: true, bargeIn: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechQueued)
        // Interrupted means words were heard and taken: a sound that only
        // ducked the reply is not an interruption (NoiseBargeInTests,
        // `aTapDuringANoiseDuckPausesRatherThanDestroys`).
        interrupt(&m)
        let down = m.handle(.holdDown)
        #expect(!down.contains(.abandonReply))
        #expect(m.state == .capturing(.hold))
        _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        #expect(m.handle(.transcribed(turn: turn, "no wait, the other one")).contains(.abandonReply))
    }

    // MARK: Stale results

    @Test func aTranscriptForAnAbandonedTurnIsDropped() {
        var m = machine()
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)      // turn 1 deciding
        _ = m.handle(.holdDown)                             // new turn while deciding
        #expect(m.state == .capturing(.hold))
        #expect(m.handle(.transcribed(turn: 1, "old words")) == [])
        #expect(m.state == .capturing(.hold))
        _ = m.handle(.holdUp)
        let out = m.handle(.transcribed(turn: 2, "new words"))
        #expect(out.contains(.submit("new words")))
    }

    /// A hold over Moe thinking replaces the turn once it says something;
    /// the press itself drops nothing (a tap there changes nothing).
    @Test func holdDuringThinkingAbandonsTheReplyForWords() {
        var m = machine()
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 1, "first"))
        let down = m.handle(.holdDown)
        #expect(!down.contains(.abandonReply))
        #expect(m.state == .capturing(.hold))
        _ = m.handle(.holdUp)
        let out = m.handle(.transcribed(turn: 2, "second"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submit("second")))
    }

    // MARK: Stop everything

    @Test func stopAllFromSpeakingGoesToRest() {
        var m = machine(wake: true, conversation: true)
        speakTurn(&m, open: .woke)
        _ = m.handle(.speechQueued)
        let out = m.handle(.stopAll)
        #expect(out.contains(.stopSpeaking))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.conversationEnded))
        #expect(m.state == .standby)
    }

    @Test func stopAllWhenNothingIsOpenIsQuiet() {
        var m = machine()
        let out = m.handle(.stopAll)
        #expect(!out.contains(.conversationEnded))
        #expect(m.state == .off)
    }

    // MARK: Asides

    @Test func anAsideSpeaksFromRestAndReturnsThere() {
        var m = machine(wake: true)
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.aside))
        #expect(!m.inConversation)
        let out = m.handle(.ttsDrained)
        #expect(m.state == .standby)
        #expect(!out.contains(.conversationEnded))
    }

    @Test func theHotkeyOverAnAsideStopsItAndListens() {
        var m = machine()
        _ = m.handle(.speechQueued)
        let out = m.handle(.toggle)
        #expect(out.contains(.stopSpeaking))
        #expect(m.state == .attending(.hotkey))
        #expect(out.contains(.armTimer(.attend, seconds: 8)))
    }

    @Test func nothingMayTalkOverYou() {
        var m = machine()
        _ = m.handle(.holdDown)
        #expect(m.handle(.speechQueued) == [])
        #expect(m.state == .capturing(.hold))
    }

    // MARK: Suspend (dictation, meeting)

    @Test func suspendStopsSpeechAndResumeRests() {
        var m = machine(wake: true)
        _ = m.handle(.toggle)
        let out = m.handle(.suspend)
        #expect(out.contains(.stopSpeaking))
        #expect(out.contains(.cancelTimer(.attend)))
        #expect(m.state == .suspended)
        #expect(!out.contains(.audio(false)))     // the dictation is using it
        _ = m.handle(.resume)
        #expect(m.state == .standby)
    }

    @Test func aReplyOwedAcrossASuspendComesBackToThinking() {
        var m = machine()
        speakTurn(&m, open: .toggle)
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.suspend)
        _ = m.handle(.resume)
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .off)
    }

    @Test func aReplyThatFinishedDuringASuspendIsNotOwed() {
        var m = machine()
        speakTurn(&m, open: .toggle)
        _ = m.handle(.suspend)
        _ = m.handle(.brainFinished)
        _ = m.handle(.resume)
        #expect(m.state == .off)
    }

    @Test func holdIsIgnoredWhileSuspended() {
        var m = machine()
        _ = m.handle(.suspend)
        #expect(m.handle(.holdDown) == [])
        #expect(m.handle(.woke) == [])
        #expect(m.handle(.toggle) == [])
    }

    // MARK: The nets under the endpointer (review findings)

    @Test func silenceWithNoWordsEndsTheTurnAnyway() {
        var m = machine()
        _ = m.handle(.toggle)
        let start = m.handle(.speechStarted)               // a cough
        #expect(start.contains(.armTimer(.turnCap, seconds: 90)))
        let end = m.handle(.speechEnded)
        #expect(end.contains(.armTimer(.silence, seconds: 1.5)))
        // Sound again does *not* cancel the fallback — only words would…
        #expect(!m.handle(.speechStarted).contains(.cancelTimer(.silence)))
        _ = m.handle(.speechEnded)
        // …and the fallback firing (after one reprieve for that onset)
        // decides the turn like an endpoint would.
        _ = m.handle(.timer(.silence))
        let out = m.handle(.timer(.silence))
        #expect(out.contains(.transcribe(turn: 1)))
        #expect(out.contains(.cancelTimer(.turnCap)))
        let back = m.handle(.transcribed(turn: 1, ""))
        #expect(m.state == .attending(.hotkey))
        #expect(back.contains(.armTimer(.attend, seconds: 8)))
    }

    // MARK: The pause that was a breath

    /// Measured 2026-09-07 11:10:18Z: "…I'm right now sitting in my balcony
    /// in my backyard" — finished, p=0.94, and the person went on. The
    /// microphone never closed, the read of the first half is kept, and the
    /// second half is joined to it: one turn to the brain.
    @Test func goingOnWhileTheFirstHalfIsReadJoinsTheHalves() {
        var m = machine(wake: true); m.tuning.turnModel = true
        _ = m.handle(.woke); _ = m.handle(.speechStarted)
        _ = m.handle(.speechEnded); _ = m.handle(.endOfUtterance("sitting in my backyard"))
        let decided = m.handle(.turnVerdict(complete: true))
        #expect(decided.contains(.transcribe(turn: 1)))
        #expect(!decided.contains(.capture(false)))
        #expect(!decided.contains(.asr(false)))
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(1))
        let read = m.handle(.transcribed(turn: 1, "I'm sitting in my backyard"))
        #expect(!read.contains { if case .submit = $0 { return true }; return false })
        #expect(m.state == .capturing(.wake))
        _ = m.handle(.speechEnded); _ = m.handle(.endOfUtterance("and it is a lovely day"))
        _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(.wake, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "and it's a lovely day"))
        #expect(out.contains(.submit("I'm sitting in my backyard and it's a lovely day")))
        #expect(m.state == .thinking(.wake))
    }

    @Test func goingOnWhileMoeThinksWithdrawsTheHalfAnswer() {
        var m = machine()      // no barge-in: nothing is playing to barge into
        speakTurn(&m, open: .toggle, text: "add milk")
        #expect(m.state == .thinking(.hotkey))
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(3))
        #expect(m.state == .capturing(.hotkey))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(.hotkey, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "and eggs to the list"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submitContinuation("add milk and eggs to the list")))
        #expect(m.state == .thinking(.hotkey))
    }

    @Test func aCoughWhileMoeThinksKeepsTheDoorOpen() {
        var m = machine()
        speakTurn(&m, open: .toggle)
        _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(1)); _ = m.handle(.endOfUtterance(""))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, ""))
        #expect(out.contains(.resumeReply))
        #expect(m.state == .thinking(.hotkey))
        // Still unheard, so the person can still go on.
        _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(1))
        #expect(m.state == .capturing(.hotkey))
    }

    @Test func onceTheReplyIsQueuedAVoiceIsAnInterruptionNotAContinuation() {
        var m = machine()      // barge-in off: a voice over the reply does nothing
        speakTurn(&m, open: .toggle)
        let queued = m.handle(.speechQueued)
        #expect(queued.contains(.capture(false)))
        #expect(m.state == .speaking(.hotkey))
        #expect(m.handle(.speechStarted) == [.ignoredInterruptionsOff(byName: false)])
    }

    @Test func theKeysReleaseOpensNoDoor() {
        var m = machine()
        _ = m.handle(.holdDown); _ = m.handle(.speechStarted)
        let out = m.handle(.holdUp)
        #expect(out.contains(.capture(false)))
        #expect(m.handle(.speechStarted) == [])
    }

    @Test func wordsInTheWindowGetTheSameGatesAsACapture() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        m.tuning.turnModel = true
        _ = m.handle(.speechQueued); _ = m.handle(.brainFinished); _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        let out = m.handle(.endOfUtterance("and then send it to"))
        #expect(m.state == .capturing(.followUp))
        #expect(out.contains(.armTimer(.silence, seconds: 3)))
        #expect(!out.contains { if case .transcribe = $0 { return true }; return false })
    }

    @Test func theTurnModelEndsAFinishedThoughtAtThePause() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted)
        _ = m.handle(.speechEnded)
        let out = m.handle(.turnVerdict(complete: true))
        #expect(out.contains(.transcribe(turn: 1)))
        #expect(out.contains(.cancelTimer(.silence)))
    }

    @Test func theTurnModelHoldsTheDoorMidThought() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted)
        _ = m.handle(.speechEnded)
        let out = m.handle(.turnVerdict(complete: false))
        #expect(out.contains(.armTimer(.silence, seconds: 3.0)))
        #expect(m.state == .capturing(.hotkey))
        // Speech resuming — words after an onset — cancels it; the
        // endpointer can still end it.
        _ = m.handle(.speechStarted)
        #expect(m.handle(.wordsHeard(2)).contains(.cancelTimer(.silence)))
        #expect(m.handle(.endOfUtterance("send it to Anna")).contains(.transcribe(turn: 1)))
    }

    @Test func aVerdictAfterTheTurnEndedIsIgnored() {
        var m = machine()
        _ = m.handle(.holdDown)
        #expect(m.handle(.turnVerdict(complete: true)) == [])
        _ = m.handle(.holdUp)
        #expect(m.handle(.turnVerdict(complete: true)) == [])
    }

    @Test func aLongSentenceWithNoPauseIsNeverCutByTheNoSpeechTimer() {
        var m = machine()
        _ = m.handle(.toggle)
        let start = m.handle(.speechStarted)
        // No no-speech timer is armed by the speech itself (the host only
        // fires a timer it was told to arm), so nothing can cut this turn
        // but a pause or the cap.
        #expect(!start.contains { if case .armTimer(.silence, _) = $0 { return true } else { return false } })
        #expect(start.contains(.armTimer(.turnCap, seconds: 90)))
        #expect(m.state == .capturing(.hotkey))
        // In the window too.
        var w = machine(conversation: true)
        speakTurn(&w, open: .toggle); _ = w.handle(.brainFinished)
        let s2 = w.handle(.speechStarted)
        #expect(!s2.contains { if case .armTimer(.silence, _) = $0 { return true } else { return false } })
    }

    @Test func theWakeNoSpeechTimerIsCancelledByTheFirstSpeech() {
        var m = machine(wake: true)
        _ = m.handle(.woke)
        #expect(m.handle(.speechStarted).contains(.cancelTimer(.silence)))
    }

    @Test func aWakeWithNothingBehindItGivesUpWithoutAVad() {
        var m = machine(wake: true)
        let out = m.handle(.woke)
        #expect(out.contains(.armTimer(.silence, seconds: 4.0)))
        let end = m.handle(.timer(.silence))
        #expect(end.contains(.transcribe(turn: 1)))
        _ = m.handle(.transcribed(turn: 1, ""))
        #expect(m.state == .attending(.wake))
    }

    @Test func stopAllOverANudgeWhileWaitingReportsTheSessionEnded() {
        var m = machine()
        _ = m.handle(.toggle)
        _ = m.handle(.speechQueued)              // nudge over attending
        let out = m.handle(.stopAll)
        #expect(out.contains(.conversationEnded))
        #expect(m.state == .off)
    }

    @Test func aHeldTurnHasNoSilenceFallback() {
        var m = machine()
        _ = m.handle(.holdDown)
        #expect(m.handle(.speechEnded) == [])
        #expect(m.handle(.timer(.silence)) == [])
        #expect(m.state == .capturing(.hold))
    }

    @Test func endOfUtteranceInTheWindowIsATurn() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.brainFinished)
        #expect(m.state == .followUp)
        let out = m.handle(.endOfUtterance("and tomorrow"))   // no VAD edge
        #expect(out.contains(.cancelTimer(.followUp)))
        #expect(out.contains(.transcribe(turn: 2)))
    }

    @Test func aTapOfTheKeyRecordsNothingAndKeepsTheWindow() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.brainFinished)
        _ = m.handle(.holdDown)
        let out = m.handle(.holdCancelled)
        #expect(!out.contains { if case .transcribe = $0 { return true } else { return false } })
        #expect(m.state == .followUp)
        var m2 = machine(wake: true)
        _ = m2.handle(.holdDown)
        _ = m2.handle(.holdCancelled)
        #expect(m2.state == .standby)
    }

    @Test func aDictationDuringTheReadBackKeepsTheTurn() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("x"))
        _ = m.handle(.suspend)
        // Result arrives while the dictation still has the microphone.
        #expect(m.handle(.transcribed(turn: 1, "what time is it")) == [])
        let out = m.handle(.resume)
        #expect(out.contains(.submit("what time is it")))
        #expect(m.state == .thinking(.hotkey))
    }

    @Test func aDictationDuringTheReadBackWaitsForItsResult() {
        var m = machine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("x"))
        _ = m.handle(.suspend)
        _ = m.handle(.resume)
        if case .deciding(.hotkey, 1) = m.state {} else { Issue.record("\(m.state)") }
        let out = m.handle(.transcribed(turn: 1, "later"))
        #expect(out.contains(.submit("later")))
    }

    @Test func aSessionEndedByADictationIsReportedEnded() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.brainFinished)
        #expect(m.state == .followUp)
        _ = m.handle(.suspend)
        let out = m.handle(.resume)
        #expect(out.contains(.conversationEnded))
        #expect(m.state == .off)
        // The window did not leak into the next session.
        _ = m.handle(.holdDown); _ = m.handle(.holdUp)
        _ = m.handle(.transcribed(turn: 2, "hi"))
        _ = m.handle(.brainFinished)
        #expect(m.state == .off)
    }

    @Test func aNudgeWhileWaitingIsSaidAndWaitingResumes() {
        var m = machine()
        _ = m.handle(.toggle)
        let q = m.handle(.speechQueued)
        #expect(q.contains(.cancelTimer(.attend)))
        #expect(m.state == .speaking(.aside))
        #expect(m.inConversation)
        #expect(!q.contains(.conversationEnded))
        let done = m.handle(.ttsDrained)
        #expect(m.state == .attending(.hotkey))
        #expect(done.contains(.armTimer(.attend, seconds: 8)))
    }

    @Test func aNudgeInTheWindowComesBackToTheWindow() {
        var m = machine(conversation: true)
        speakTurn(&m, open: .toggle)
        _ = m.handle(.brainFinished)
        _ = m.handle(.speechQueued)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
    }

    // MARK: Derived outputs never drift

    @Test func everyRestingStateHasNoCaptureAndNoAsrExceptStandby() {
        var m = M()
        // Walk a whole conversation and check the last action of each kind.
        var asr = false, capture = false, audio = false
        func apply(_ acts: [A]) {
            for a in acts {
                switch a {
                case .asr(let v): asr = v
                case .capture(let v): capture = v
                case .audio(let v): audio = v
                default: break
                }
            }
        }
        apply(m.handle(.setWake(true)))
        #expect(asr && !capture && audio)
        apply(m.handle(.woke)); #expect(asr && capture)
        // Decided and thinking are not resting states any more: the door
        // stays open for the rest of the turn until the reply is heard.
        apply(m.handle(.endOfUtterance("x"))); #expect(asr && capture)
        apply(m.handle(.transcribed(turn: 1, "x"))); #expect(asr && capture)
        apply(m.handle(.speechQueued)); #expect(!asr && !capture)
        apply(m.handle(.brainFinished)); apply(m.handle(.ttsDrained))
        #expect(m.state == .standby && asr && !capture && audio)
        apply(m.handle(.setWake(false)))
        #expect(!asr && !capture && !audio)
    }
}

/// The failure this pins is the owner's, 2026-09-06 03:37: the turn model
/// said mid-thought and a timer took his turn three seconds later, mid-clause.
/// The worse of the two in his log is the one at p=0.01 — the model as certain
/// as it gets that he was still going, right after he said out loud "let me
/// think about this a second" — cut off two seconds later.
struct MidClauseWaitTests {

    /// Mid-turn, at the pause where the model is asked — the same setup the
    /// existing turn-model tests use.
    private func atThePause() -> VoiceMachine {
        var m = VoiceMachine()
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.speechEnded)
        return m
    }

    private func silenceSeconds(in out: [VoiceMachine.Action]) -> Double? {
        for a in out { if case .armTimer(.silence, let s) = a { return s } }
        return nil
    }

    @Test func bothSignalsUnfinishedWaitsLonger() {
        var m = atThePause()
        let out = m.handle(.turnVerdict(complete: false, stillMidClause: true))
        #expect(silenceSeconds(in: out) == m.tuning.midClauseSilenceSeconds)
    }

    @Test func finishedButMidPhraseHoldsTheDoorBriefly() {
        var m = atThePause()
        let out = m.handle(.turnVerdict(complete: true, stillMidClause: true))
        #expect(out.contains(.armTimer(.verdictHold, seconds: m.tuning.verdictHoldSeconds)))
        #expect(m.state == .capturing(.hotkey))
        // Speech resumes — words after an onset: the hold is dropped and
        // the turn goes on.
        _ = m.handle(.speechStarted)
        let more = m.handle(.wordsHeard(2))
        #expect(more.contains(.cancelTimer(.verdictHold)))
        #expect(m.state == .capturing(.hotkey))
    }

    @Test func theHoldExpiringTakesTheVerdict() {
        var m = atThePause()
        _ = m.handle(.turnVerdict(complete: true, stillMidClause: true))
        _ = m.handle(.timer(.verdictHold))
        guard case .deciding = m.state else { Issue.record("not deciding: \(m.state)"); return }
    }

    @Test func finishedWithTheWordsAgreeingDecidesAtOnce() {
        var m = atThePause()
        _ = m.handle(.turnVerdict(complete: true, stillMidClause: false))
        guard case .deciding = m.state else { Issue.record("not deciding: \(m.state)"); return }
    }

    @Test func theAudioModelAloneKeepsTheOrdinaryWait() {
        var m = atThePause()
        let out = m.handle(.turnVerdict(complete: false, stillMidClause: false))
        #expect(silenceSeconds(in: out) == m.tuning.incompleteSilenceSeconds)
    }

    /// The longer wait must actually be longer, or this is decoration.
    @Test func theLongerWaitIsLonger() {
        let t = VoiceMachine.Tuning()
        #expect(t.midClauseSilenceSeconds > t.incompleteSilenceSeconds)
    }

    /// It only applies to "not finished". A finished verdict still ends the
    /// turn at once, whatever the words looked like — otherwise every reply
    /// ending in a preposition would hang.
    /// "Finished" with the words disagreeing no longer ends the turn on the
    /// spot (see `finishedButMidPhraseHoldsTheDoorBriefly`), but it must
    /// not arm the long silence clocks either: the hold is its own timer.
    @Test func finishedButMidPhraseArmsNoSilenceClock() {
        var m = atThePause()
        let out = m.handle(.turnVerdict(complete: true, stillMidClause: true))
        #expect(silenceSeconds(in: out) == nil)
    }

    /// The default call site must keep meaning what it meant.
    @Test func theDefaultIsTheOrdinaryWait() {
        var m = atThePause()
        let out = m.handle(.turnVerdict(complete: false))
        #expect(silenceSeconds(in: out) == m.tuning.incompleteSilenceSeconds)
    }
}
