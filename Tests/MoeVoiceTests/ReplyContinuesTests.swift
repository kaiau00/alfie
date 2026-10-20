import Foundation
import Testing
@testable import MoeVoice

/// The stall guard's one continuation (docs/FIXABLE-FAILURES.md bug 9), as
/// the voice sees it: the brain went back into a reply it had just finished,
/// and the reply is owed again the way a spoken turn's is.
///
/// Without `.replyContinues` the machine closed the reply at `.brainFinished`
/// and went to the follow-up window (or to rest) while the brain worked on:
/// the key could not interrupt the continuation, what the person said next
/// was dropped as "still working on the last one", and the continuation's
/// answer came out as an aside.
struct ReplyContinuesTests {

    typealias M = VoiceMachine

    private func machine() -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        m.tuning.wakeHead = true
        _ = m.handle(.setWake(true))
        return m
    }

    /// A hotkey turn answered with the promise, which is still being said
    /// when the brain finishes.
    private func promiseBeingSaid(_ m: inout M) {
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("not deciding: \(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "find me a flight to Kunming"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        #expect(m.state == .speaking(.hotkey))
    }

    /// The promise plays out while the continuation works: the machine parks
    /// in thinking, as a reply still being written does — not the window.
    @Test func thePromiseRunsOutIntoThinkingNotTheFollowUp() {
        var m = machine()
        promiseBeingSaid(&m)
        _ = m.handle(.replyContinues)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .thinking(.hotkey))
        // …and the continuation's answer is the reply, not an aside.
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
    }

    /// Without it — the bug: the promise drains into the window while the
    /// brain is still working.
    @Test func withoutItThePromiseDrainsIntoTheWindow() {
        var m = machine()
        promiseBeingSaid(&m)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
    }

    /// Already in the window when the continuation starts: back to thinking.
    @Test func fromTheFollowUpWindowItIsOwedAgain() {
        var m = machine()
        promiseBeingSaid(&m)
        _ = m.handle(.ttsDrained)
        #expect(m.state == .followUp)
        let out = m.handle(.replyContinues)
        #expect(out.contains(.cancelTimer(.followUp)))
        #expect(m.state == .thinking(.followUp))
    }

    /// The key interrupts the continuation like any reply in flight: the
    /// host is told to abandon it, so the person's words are the next turn
    /// rather than being dropped behind it.
    @Test func theKeyInterruptsTheContinuation() {
        var m = machine()
        promiseBeingSaid(&m)
        _ = m.handle(.ttsDrained)
        _ = m.handle(.replyContinues)
        let out = m.handle(.toggle)
        #expect(out.contains(.abandonReply))
    }

    /// A turn the machine never carried — typed, and read out from rest —
    /// is untouched.
    @Test func aTurnTheMachineNeverCarriedIsUntouched() {
        var m = machine()
        let before = m.state
        #expect(m.handle(.replyContinues).isEmpty)
        #expect(m.state == before)
    }
}
