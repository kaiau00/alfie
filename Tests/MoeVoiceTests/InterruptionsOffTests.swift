import Foundation
import Testing
@testable import MoeVoice

/// Interrupt off means off (the owner, 2026-09-25): with `bargeIn` false,
/// nothing said while Moe is thinking or speaking stops or restarts it. The
/// key and the island's buttons still do.
///
/// What it was, from the owner's log that day (`moe.log`, `turns.jsonl`):
///
///     14:58:21  capturing(followUp) → deciding(followUp #45)
///     14:58:22  turn 45 … bargeIn=false → submitted   ("…respond first to Lou…")
///     14:58:25  barge-in over thinking(followUp): taken by continuation
///               (continuedAfterMs 5098 — 4.2 s after the decision)
///     14:58:29  "Oh, do you hear me?" → reply abandoned after 0 chars heard;
///               "continued — asking again with both halves"
///
/// The continuation window ignored `bargeIn` and stayed open until the first
/// audible word — however long the brain took. Now, with interruptions off,
/// it takes a voice only inside `continuationGraceSeconds` of the decision.
/// The grace is measured: of 15 continuations in the owner's traces
/// (2026-09-24 → 09-25) ten resumed 0.97–2.32 s after the last word, the
/// decision landing ~0.93 s after it (0.06–1.4 s after the decision); the
/// other five were 3.3–15.1 s, 14:58:25 among them.
struct InterruptionsOffTests {

    typealias M = VoiceMachine

    private func machine(bargeIn: Bool) -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = bargeIn
        _ = m.handle(.setWake(false))
        return m
    }

    /// A first exchange, heard to its end, so the next turn is in the window
    /// — as turn 45 was.
    private func intoTheWindow(_ m: inout M) {
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "hi"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
    }

    /// The turn decided and sent; returns what the decision emitted.
    @discardableResult
    private func turn45(_ m: inout M) -> [M.Action] {
        _ = m.handle(.speechStarted)
        _ = m.handle(.speechEnded)
        let decided = m.handle(.endOfUtterance("respond first to lou"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return decided }
        _ = m.handle(.transcribed(turn: turn, "Okay, so let's respond first to Lou, and then we'll take it from there"))
        #expect(m.state == .thinking(.followUp))
        return decided
    }

    private func isCapturing(_ s: M.State) -> Bool {
        if case .capturing = s { return true }
        return false
    }

    // MARK: 14:58, replayed

    @Test func talkingLongAfterTheDecisionDoesNotRestartTheReply() {
        var m = machine(bargeIn: false)
        intoTheWindow(&m)
        let decided = turn45(&m)
        #expect(decided.contains(.armTimer(.continuationGrace, seconds: 3.0)))

        // 3 s after the decision: the grace is over and the mic is let go.
        let grace = m.handle(.timer(.continuationGrace))
        #expect(grace.contains(.asr(false)))
        #expect(grace.contains(.capture(false)))

        // 14:58:25 — a voice, 4.2 s after the decision.
        var all = m.handle(.speechStarted)
        #expect(all.contains(.ignoredInterruptionsOff(byName: false)))
        #expect(!all.contains(.asr(true)))
        all += m.handle(.wordsGrew)
        all += m.handle(.wordsHeard(5, urgent: false))           // "Oh, do you hear me?"
        all += m.handle(.speechEnded)
        all += m.handle(.endOfUtterance("oh do you hear me"))
        #expect(m.state == .thinking(.followUp))
        #expect(!all.contains(.abandonReply))
        #expect(!all.contains { if case .submitContinuation = $0 { return true }; return false })
        #expect(!all.contains(.onsetTaken(.continuation)))
        #expect(!all.contains(.duckSpeech(true)))
        // Said once per reply, not once per sound.
        #expect(!m.handle(.speechStarted).contains(.ignoredInterruptionsOff(byName: false)))

        // And once the reply plays, a voice over it is ignored too.
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.followUp))
        var over = m.handle(.speechStarted)
        over += m.handle(.speechRose)
        over += m.handle(.wordsHeard(3, urgent: true))              // "stop, stop"
        #expect(m.state == .speaking(.followUp))
        #expect(!over.contains(.pauseSpeech))
        #expect(!over.contains(.stopSpeaking))
        #expect(!over.contains(.duckSpeech(true)))
        #expect(!over.contains(.judgeBargeIn))
    }

    /// Reversed by the owner on 2026-10-06: five wakes over a reply were
    /// ignored 09-29 → 09-30, two ending on the hotkey. The name stops it;
    /// any other voice still does not (the test above). The host feeds only
    /// a sure wake here (`WakeOwnerCheck.stopsReplyAtHead`).
    @Test func theNameOverTheReplyStopsIt() {
        var m = machine(bargeIn: false)
        intoTheWindow(&m)
        turn45(&m)
        _ = m.handle(.speechQueued)
        let out = m.handle(.woke)
        #expect(out.contains(.stopSpeaking))
        #expect(!out.contains(.ignoredInterruptionsOff(byName: true)))
        #expect(m.state != .speaking(.followUp))
    }

    @Test func theKeyAndTheButtonsStillWork() {
        var m = machine(bargeIn: false)
        intoTheWindow(&m)
        turn45(&m)
        _ = m.handle(.timer(.continuationGrace))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        // A tap holds it.
        _ = m.handle(.holdDown)
        _ = m.handle(.holdCancelled)
        #expect(m.state == .speaking(.followUp))
        // The island's stop.
        let stop = m.handle(.stopAll)
        #expect(stop.contains(.stopSpeaking))
        #expect(m.state == .off)
    }

    // MARK: Inside the grace, the sentence still joins

    @Test func goingOnInsideTheGraceStillJoinsTheTurn() {
        var m = machine(bargeIn: false)
        intoTheWindow(&m)
        turn45(&m)
        // 0.4 s after the decision (14:51:48's 1318 ms pause): "uhh…"
        _ = m.handle(.speechStarted)
        // The grace runs out while the words are still coming: the onset
        // began inside it, so it is still the same sentence.
        _ = m.handle(.timer(.continuationGrace))
        _ = m.handle(.wordsGrew)
        #expect(isCapturing(m.state))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "and tell him Tuesday"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains(.submitContinuation(
            "Okay, so let's respond first to Lou, and then we'll take it from there and tell him Tuesday")))
    }

    @Test func goingOnWhileTheFirstHalfIsReadBackStillJoins() {
        var m = machine(bargeIn: false)
        intoTheWindow(&m)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("respond first to lou"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsGrew)
        // The grace ends mid-sentence: the capture of the second half stays.
        let grace = m.handle(.timer(.continuationGrace))
        #expect(!grace.contains(.capture(false)))
        _ = m.handle(.transcribed(turn: turn, "respond first to Lou"))
        #expect(isCapturing(m.state))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let second) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: second, "and tell him Tuesday"))
        #expect(out.contains(.submit("respond first to Lou and tell him Tuesday")))
    }

    // MARK: Interruptions on: unchanged

    @Test func withInterruptionsOnTheWindowRunsToTheFirstWordAsBefore() {
        var m = machine(bargeIn: true)
        intoTheWindow(&m)
        let decided = turn45(&m)
        #expect(!decided.contains { if case .armTimer(.continuationGrace, _) = $0 { return true }; return false })
        // A stray grace timer changes nothing.
        #expect(m.handle(.timer(.continuationGrace)).isEmpty)
        // 4.2 s later, the same voice goes on with the turn, as it always did.
        _ = m.handle(.speechStarted)
        let took = m.handle(.wordsGrew)
        #expect(took.contains(.onsetTaken(.continuation)))
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "Oh, do you hear me?"))
        #expect(out.contains(.abandonReply))
        #expect(out.contains { if case .submitContinuation = $0 { return true }; return false })
        #expect(!out.contains(.ignoredInterruptionsOff(byName: false)))
    }

    @Test func withInterruptionsOnTheNameStillStopsTheReply() {
        var m = machine(bargeIn: true)
        intoTheWindow(&m)
        turn45(&m)
        _ = m.handle(.speechQueued)
        let out = m.handle(.woke)
        #expect(out.contains(.stopSpeaking))
    }
}
