import Foundation
import Testing
@testable import MoeVoice

/// A single tap of the talk key never throws an answer away.
///
/// Measured on the owner's Mac (186 double-taps, to 2026-10-13): a tap
/// paused a reply that was being spoken, but the same tap while Moe was
/// thinking — or between two sentences while a tool ran, or over a reply a
/// barge-in had paused — withdrew the turn, and the answer never came. The
/// grammar is now the same in every state:
///
/// | gesture | over a turn in progress |
/// |---|---|
/// | tap | pause what is playing; with nothing playing, change nothing |
/// | hold, then words | replace it |
/// | double-tap | stop everything |
struct TapNeverDestroysTests {

    typealias M = VoiceMachine
    typealias A = M.Action

    private func machine() -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.setWake(true))
        return m
    }

    /// Asked, and waiting on the brain: nothing of the answer heard yet.
    private func thinking() -> M {
        var m = machine()
        _ = m.handle(.toggle)
        _ = m.handle(.speechStarted)
        _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else {
            Issue.record("not deciding: \(m.state)"); return m
        }
        _ = m.handle(.transcribed(turn: turn, "what is on my calendar"))
        #expect(m.state == .thinking(.hotkey))
        return m
    }

    private func tap(_ m: inout M) -> [A] {
        var out = m.handle(.holdDown)
        out += m.handle(.holdCancelled)
        return out
    }

    private func submits(_ out: [A]) -> Bool {
        out.contains { if case .submit = $0 { return true }; if case .submitContinuation = $0 { return true }; return false }
    }

    @Test func aTapWhileMoeThinksKeepsTheTurn() {
        var m = thinking()
        let out = tap(&m)
        #expect(!out.contains(.abandonReply), "the turn was withdrawn by a tap")
        #expect(!out.contains(.replyHeld(true)), "nothing was playing, so nothing is paused")
        #expect(m.state == .thinking(.hotkey))
        // …and the answer, when it comes, is heard.
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func aTapBetweenSentencesLeavesTheReplyAlone() {
        var m = thinking()
        _ = m.handle(.speechQueued)          // the first sentence plays
        _ = m.handle(.ttsDrained)            // …and runs out while a tool works
        #expect(m.state == .thinking(.hotkey))
        let out = tap(&m)
        #expect(!out.contains(.abandonReply), "the rest of the answer was thrown away")
        #expect(m.state == .thinking(.hotkey))
        // The next sentence plays, and a tap over it is the pause button.
        _ = m.handle(.speechQueued)
        #expect(m.state == .speaking(.hotkey))
        let pause = tap(&m)
        #expect(pause.contains(.replyHeld(true)))
        #expect(!pause.contains(.abandonReply))
    }

    @Test func aTapWhileThinkingAfterTheBrainFinishedPlaysTheReply() {
        var m = thinking()
        _ = m.handle(.holdDown)
        _ = m.handle(.brainFinished)         // the answer landed during the tap
        let out = m.handle(.holdCancelled)
        #expect(!out.contains(.abandonReply))
        #expect(out.contains(.resumeReply), "the finished answer must be queued to be heard")
        #expect(m.state == .speaking(.hotkey))
    }

    @Test func aHoldWithWordsWhileMoeThinksReplacesTheTurn() {
        var m = thinking()
        _ = m.handle(.holdDown)
        _ = m.handle(.holdUp)
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        let out = m.handle(.transcribed(turn: turn, "actually never mind that"))
        #expect(out.contains(.abandonReply))
        #expect(submits(out))
    }

    @Test func aDoubleTapWhileMoeThinksAbandonsAndRests() {
        var m = thinking()
        // The first tap of a double-tap goes down; the second stops all.
        var out = m.handle(.holdDown)
        out += m.handle(.stopAll)
        #expect(out.contains(.abandonReply))
        #expect(m.state == .standby)
        #expect(!m.inConversation)
    }

    @Test func aTapOverABargeInPausesRatherThanDrops() {
        var m = thinking()
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        #expect(m.state == .speaking(.hotkey))
        // Someone talks over it; the judge says it is the person.
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(2))
        _ = m.handle(.bargeInJudged(true))
        guard case .capturing = m.state else { Issue.record("not capturing: \(m.state)"); return }
        let out = tap(&m)
        #expect(!out.contains(.abandonReply), "the key dropped a reply a barge-in had only paused")
        #expect(m.state == .speaking(.hotkey))
        #expect(tap(&m).contains(.resumeReply))
    }
}
