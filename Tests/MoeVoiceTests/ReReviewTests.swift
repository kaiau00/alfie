import Foundation
import Testing
@testable import MoeVoice

/// The re-review of the fix round (voice-turns-review.md, "Re-review").
struct ReReviewTests {

    typealias S = BargeInJudge.Signals

    private func stop(_ heard: String, playing: String) -> BargeInDecision {
        var s = S(window: "speaking", words: 1, urgent: true, heard: heard, levelRatio: 0.9)
        s.urgentEchoesPlayhead = BargeInJudge.echoesThePlayhead(heard: heard, playing: playing)
        return BargeInJudge.decide(s)
    }

    // MARK: N1 — Moe's own stop word, coming back

    @Test func moesOwnWaitDoesNotPauseTheReply() {
        let d = stop("wait", playing: "Okay, wait for it — the next part is the good bit.")
        #expect(!d.taken && d.check == .echoText)
    }

    @Test func theOwnersWaitStillDoes() {
        let d = stop("wait", playing: "The next part is the good bit, and then there's more.")
        #expect(d.taken && d.check == .words)
    }

    @Test func moesOwnNameComingBackIsEchoTooButNotAnotherWord() {
        #expect(BargeInJudge.echoesThePlayhead(heard: "moe", playing: "I'm Moe, and I can help with that."))
        #expect(!BargeInJudge.echoesThePlayhead(heard: "no", playing: "I don't know if that's on."))   // whole words
        #expect(!BargeInJudge.echoesThePlayhead(heard: "wait stop", playing: "wait for it"))           // "stop" is new
    }

    // MARK: N2 — the stop word revised away

    @Test func aStopWordRevisedAwayIsNoLongerUrgent() {
        var r = WordReport()
        let first = r.update(text: "no", baseline: 0, countNods: false)
        #expect(first?.urgent == true)
        _ = r.update(text: "nothing", baseline: 0, countNods: false)
        #expect(!r.urgent)
        var m = WordReport()
        _ = m.update(text: "the mo", baseline: 0, countNods: false)
        #expect(m.urgent)
        _ = m.update(text: "the moment", baseline: 0, countNods: false)
        #expect(!m.urgent)
    }

    // MARK: N3 — whole tokens, and the configured wake phrases

    @Test func theNameIsAWholeTokenAndCustomPhrasesCount() {
        #expect(!NameMatch.namesMoe("my chemo is on friday"))
        #expect(!NameMatch.namesMoe("remember the alamo"))
        #expect(!NameMatch.namesMoe("I need to mow the lawn"))
        #expect(NameMatch.namesMoe("mow, stop"))
        let custom = WakeSpotter(phrases: ["hey jarvis"])
        #expect(NameMatch.namesMoe("hey jarvis stop", spotter: custom))
        #expect(!NameMatch.namesMoe("hey jarvis stop"))
    }

    // MARK: H2 wiring — the pre-roll is not the person

    @Test func theOwnerIsScoredWithoutThePreRoll() {
        let capture = [Float](repeating: 0.5, count: 8_000) + [Float](repeating: 0.1, count: 20_000)
        let own = BargeInJudge.ownAudio(capture, prerollSeconds: 0.5, sampleRate: 16_000)
        #expect(own.count == 20_000)
        #expect(own.allSatisfy { $0 == 0.1 })
    }

    // MARK: H3 residual — the second half of a turn is never the gate's

    @Test func theSecondHalfOfATurnIsKnownWhileItIsRead() {
        var m = VoiceMachine()
        m.tuning.conversation = true
        m.tuning.turnModel = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded); _ = m.handle(.turnVerdict(complete: true))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        #expect(!m.decidingTheRestOfATurn)                          // the first half
        _ = m.handle(.transcribed(turn: turn, "remind me tomorrow"))
        _ = m.handle(.speechStarted); _ = m.handle(.wordsGrew)     // goes on
        _ = m.handle(.speechEnded); _ = m.handle(.turnVerdict(complete: true))
        #expect(m.decidingTheRestOfATurn)                           // the second half
        #expect(OwnerGate.outcome(.notOwner, enforce: true, continuation: m.decidingTheRestOfATurn) == .pass)
    }
}
