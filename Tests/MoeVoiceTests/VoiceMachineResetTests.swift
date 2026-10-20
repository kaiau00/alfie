import Testing
@testable import MoeVoice

private typealias M = VoiceMachine
private typealias A = VoiceMachine.Action

/// `.resetAsr` exists so "the next utterance does not arrive with the last one
/// glued to its front" — the streaming recogniser keeps encoder caches and an
/// accumulated hypothesis across turns, and `.asr(false)` does not clear them:
/// it stops frames being fed and keeps everything already accumulated.
///
/// Every route out of a turn emitted it except one: a wake- or hotkey-opened
/// turn whose accurate re-read came back empty went to `.attending` without a
/// reset, leaving the abandoned attempt in the decoder for the next utterance
/// to be appended to. A missing action is invisible from the outside — the
/// machine's state was correct either way — so it is asserted here.
struct VoiceMachineResetTests {

    private func woken() -> M {
        var m = M()
        _ = m.handle(.setWake(true))
        return m
    }

    /// Drive to `.deciding`, then hand back whatever the re-read produced.
    private func turn(_ m: inout M, open: M.Event, transcript: String) -> [A] {
        var out = m.handle(open)
        out += m.handle(.speechStarted)
        out += m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let n) = m.state else {
            Issue.record("expected .deciding, got \(m.state)")
            return out
        }
        return out + m.handle(.transcribed(turn: n, transcript))
    }

    @Test func anAbandonedWakeTurnClearsTheRecogniser() {
        var m = woken()
        let out = turn(&m, open: .woke, transcript: "")
        #expect(out.contains(.resetAsr))
        // And it is still waiting, which is the behaviour that was already
        // right and must not change.
        if case .attending = m.state {} else { Issue.record("expected .attending, got \(m.state)") }
    }

    @Test func anAbandonedHotkeyTurnClearsTheRecogniser() {
        var m = woken()
        let out = turn(&m, open: .toggle, transcript: "")
        #expect(out.contains(.resetAsr))
    }

    /// A turn that produced words is submitted, and the reset is not what
    /// carries it — this pins that the new action did not displace anything.
    @Test func aRealTurnStillReachesTheBrain() {
        var m = woken()
        let out = turn(&m, open: .woke, transcript: "what time is it")
        #expect(out.contains(.submit("what time is it")))
        #expect(!out.contains(.resetAsr))
    }
}
