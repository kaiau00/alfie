import Foundation
import Testing
@testable import MoeVoice

/// Step 1.4: the one check that turns away the TV and other people.
struct OwnerGateTests {

    typealias M = VoiceMachine

    // MARK: The rule

    /// Moe's own voice scored 0.17 against the owner's enrolment; the owner's
    /// lowest of 17 turns was 0.51. "Clearly not" is under 0.25.
    @Test func onlyAVoiceClearlyNotTheOwnersIsRefused() {
        #expect(OwnerGate.verdict(score: 0.12, enrolled: true, named: false, seconds: 1.5) == .notOwner)
        #expect(OwnerGate.verdict(score: 0.24, enrolled: true, named: false, seconds: 1.5) == .notOwner)
        // The band between is left to the addressee rules, as before.
        #expect(OwnerGate.verdict(score: 0.30, enrolled: true, named: false, seconds: 1.5) == .letThrough)
        #expect(OwnerGate.verdict(score: 0.51, enrolled: true, named: false, seconds: 1.5) == .letThrough)
    }

    /// A guest at a Mac whose owner never taught it their voice can talk.
    @Test func withoutAnEnrolmentNobodyIsRefused() {
        #expect(OwnerGate.verdict(score: 0.05, enrolled: false, named: false, seconds: 3) == .letThrough)
    }

    @Test func theNameAndAShortClipAreNeverRefused() {
        #expect(OwnerGate.verdict(score: 0.05, enrolled: true, named: true, seconds: 3) == .letThrough)
        #expect(OwnerGate.verdict(score: 0.05, enrolled: true, named: false, seconds: 0.8) == .letThrough)
        #expect(OwnerGate.verdict(score: nil, enrolled: true, named: false, seconds: 3) == .letThrough)
    }

    // MARK: The machine

    private func inTheWindow() -> M {
        var m = M()
        m.tuning.conversation = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { return m }
        _ = m.handle(.transcribed(turn: turn, "what time is it"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.brainFinished)
        _ = m.handle(.ttsDrained)
        return m
    }

    /// The TV talking into the window: the capture ends with no read, no
    /// turn, and the window is waiting again.
    @Test func aWindowCaptureInSomebodyElsesVoiceEndsUnread() {
        var m = inTheWindow()
        #expect(m.state == .followUp)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(4))
        #expect(m.state == .capturing(.followUp))
        let out = m.handle(.notTheOwner)
        #expect(out.contains(.decided(.notOwner)))
        #expect(!out.contains { if case .transcribe = $0 { return true }; return false })
        #expect(!out.contains { if case .submit = $0 { return true }; return false })
        #expect(m.state == .followUp)
    }

    /// Somebody else talking right after the person paused is not the person
    /// going on: the reply that was on its way carries on.
    @Test func aContinuationInSomebodyElsesVoiceLeavesTheReplyAlone() {
        var m = M()
        m.tuning.conversation = true
        m.tuning.turnModel = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "remind me tomorrow"))
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsGrew)
        #expect(m.capturingTheRestOfATurn)
        let out = m.handle(.notTheOwner)
        #expect(out.contains(.resumeReply))
        #expect(!out.contains(.abandonReply))
        #expect(m.state == .thinking(.hotkey))
    }

    /// Whoever holds the key is the person asking.
    @Test func theKeyIsNeverRefused() {
        var m = M()
        _ = m.handle(.holdDown)
        #expect(m.handle(.notTheOwner).isEmpty)
        #expect(m.state == .capturing(.hold))
    }
}
