import Foundation
import Testing
@testable import MoeVoice

/// The owner's own pauses as labelled data (`TurnPauses`, the debug clip's
/// `labelledHolds`) and as a habit the policy can learn (`OwnerPauses`), and
/// the replay's use of the on-device model's measured answers.
struct OwnerPausesTests {

    // MARK: Collecting

    /// Every pause the person talked through is a hold; a gap too short to be
    /// a pause is not, and a pause nobody ended (the key released in it) is
    /// not one either.
    @Test func thePausesTalkedThroughAreHolds() {
        var p = TurnPauses()
        p.ended(at: 1.0); p.started(at: 1.9)       // a 0.9 s breath
        p.ended(at: 3.0); p.started(at: 3.1)       // a gap between words
        p.ended(at: 4.0); p.started(at: 6.5)       // a 2.5 s think
        p.ended(at: 8.0)                            // the key, released in this one
        #expect(p.spans == [.init(start: 1.0, end: 1.9), .init(start: 4.0, end: 6.5)])
        #expect(p.durationsMs == [900, 2500])
        #expect(TurnPauses().durationsMs == nil)
    }

    /// A held-key clip keeps the turn's pauses, placed where they fall in the
    /// clip; a pause that starts before the clip does is dropped, not cut.
    @Test func aHeldKeyClipCarriesItsPausesInClipTime() {
        let holds = [TurnPauses.Span(start: 100.0, end: 100.9), TurnPauses.Span(start: 110.0, end: 111.0)]
        // Decided at t=115, 12 s into a 14.5 s clip: the clip starts at t=103.
        let out = VoiceDebug.labelledHolds(holds, decisionT: 115, lastWordT: nil, resumedT: nil,
                                           decidedAt: 12, clipSeconds: 14.5, label: "hold-to-talk")
        #expect(out.label == "hold-to-talk")
        #expect(out.holds.count == 1)
        #expect(abs(out.holds[0].start - 7.0) < 1e-9 && abs(out.holds[0].end - 8.0) < 1e-9)
    }

    /// The person going on inside the clip's after-part makes the decision's
    /// own pause a labelled hold and the clip a false endpoint; going on
    /// later, or never, leaves it unlabelled.
    @Test func aDecisionThePersonTalkedOnAfterIsLabelledContinued() {
        let continued = VoiceDebug.labelledHolds([], decisionT: 50, lastWordT: 49.4, resumedT: 51.2,
                                                 decidedAt: 8, clipSeconds: 10.5, label: nil)
        #expect(continued.label == "continued")
        #expect(continued.holds.count == 1)
        #expect(abs(continued.holds[0].start - 7.4) < 1e-9 && abs(continued.holds[0].end - 9.2) < 1e-9)

        let late = VoiceDebug.labelledHolds([], decisionT: 50, lastWordT: 49.4, resumedT: 53.0,
                                            decidedAt: 8, clipSeconds: 10.5, label: nil)
        #expect(late.label == nil && late.holds.isEmpty)
        let before = VoiceDebug.labelledHolds([], decisionT: 50, lastWordT: 49.4, resumedT: 49.9,
                                              decidedAt: 8, clipSeconds: 10.5, label: nil)
        #expect(before.label == nil)                 // an onset from an earlier turn
    }

    @Test func theSidecarCarriesTheLabel() throws {
        let side = VoiceDebug.Sidecar(kind: "turn", reason: "key", decidedAtSeconds: 12, clipSeconds: 14.5,
                                      holds: [.init(start: 7, end: 8)], label: "hold-to-talk")
        let back = try JSONDecoder().decode(VoiceDebug.Sidecar.self, from: side.json())
        #expect(back.label == "hold-to-talk")
        #expect(back.holds == [.init(start: 7, end: 8)])
    }

    // MARK: Learning

    private func lines(_ holdsMs: [[Int]], continued: [Int] = []) -> [String] {
        var out: [String] = []
        for h in holdsMs {
            var t = TurnTrace(source: "hotkey")
            t.holdsMs = h
            out.append(t.jsonLine()!)
        }
        for c in continued {
            var t = TurnTrace(source: "onset")
            t.continuedAfterMs = c
            out.append(t.jsonLine()!)
        }
        return out
    }

    /// Nothing changes until there is enough of the owner to go on.
    @Test func tooFewPausesChangeNothing() {
        let learnt = OwnerPauses()
        let holds = learnt.holds(fromTraceLines: lines(Array(repeating: [900], count: 49)))
        #expect(holds.count == 49)
        #expect(learnt.floor(holds) == nil)
    }

    /// With enough, the floor is the quiet 90 % of their holds fit inside —
    /// continuations included, thinking pauses left to the ceiling — and it
    /// is clamped either way.
    @Test func theFloorIsTheirHighQuantileClamped() {
        let learnt = OwnerPauses()
        // 60 holds 0.3…2.07 s in 30 ms steps, plus two 9 s thinks (dropped).
        let ms = (0..<60).map { 300 + 30 * $0 }
        let holds = learnt.holds(fromTraceLines: lines([ms, [9000]], continued: [9000]))
        #expect(holds.count == 60)
        let floor = learnt.floor(holds)
        #expect(abs((floor ?? 0) - 1.89) < 1e-9)                   // index round(59 × 0.9) = 53 of 0…59
        let jumpy = OwnerPauses().floor(Array(repeating: 0.25, count: 80))
        #expect(jumpy == 0.8)                                       // never under `lowest`
        let deaf = OwnerPauses().floor(Array(repeating: 4.9, count: 80))
        #expect(deaf == 2.5)                                        // never over `highest`
    }

    // MARK: The replay's on-device model

    private func tape() -> TurnTape {
        typealias Ev = TurnTape.Event
        let ev = [Ev(t: 0, .speechStarted), Ev(t: 0.5, .partial, "look up a good italian place"),
                  Ev(t: 0.8, .speechEnded)]
        return TurnTape(id: "m", events: ev, probes: [TurnTape.key(tail: 0.3): [.init(t: 0.8, p: 0.95)]],
                        truth: .init(holds: [], end: .init(start: 0.5, end: 8)), duration: 8)
    }

    /// The model is asked only where the rules are silent, its answer counts
    /// only inside the budget, and a late one costs the verdict the budget —
    /// what the engine does.
    @Test func theReplayUsesTheModelOnlyInsideItsBudget() throws {
        var tuning = VoiceMachine.Tuning()
        var policy = EndpointPolicy.fitted
        policy.modelFinishedLess = 1.0
        tuning.endpoint = policy
        func decidedAt(_ answer: PolicyReplay.ModelAnswer?) -> (Double, Int) {
            var c = PolicyReplay.Config(tuning: tuning, inferenceSeconds: 0.05)
            c.model = answer.map { [TurnSemantics.key("look up a good italian place"): $0] } ?? [:]
            c.modelBudget = 0.3
            let r = PolicyReplay.run(tape(), c)
            let d = r.decisions.first!
            return (d.t + d.replyHold, r.modelMissing)
        }
        let fast = decidedAt(.init(reading: .finished, ms: 120))
        let slow = decidedAt(.init(reading: .finished, ms: 900))
        let none = decidedAt(nil)
        // In time, "finished" lets the reply out a second sooner.
        #expect(fast.0 < slow.0 - 0.5)
        // Too slow: no vote, and the same release as having none.
        #expect(abs(slow.0 - none.0) < 1e-9)
        #expect(none.1 == 1 && fast.1 == 0)
    }
}
