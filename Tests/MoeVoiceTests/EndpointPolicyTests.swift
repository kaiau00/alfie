import Foundation
import Testing
@testable import MoeVoice

/// Step 1.1: the wait after a verdict planned from its evidence.
struct EndpointPolicyTests {

    typealias M = VoiceMachine
    typealias E = EndpointPolicy.Evidence

    private func capturing(_ policy: EndpointPolicy?) -> M {
        var m = M()
        m.tuning.conversation = true
        m.tuning.turnModel = true
        m.tuning.endpoint = policy
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.wordsHeard(3))
        _ = m.handle(.speechEnded)
        return m
    }

    /// `EndpointPolicy.before` is the machine as it shipped: for every score
    /// and every shape of words, the same actions as the two booleans gave.
    /// Without this, "before" in the bench table would be a policy nobody ran.
    @Test func beforeIsExactlyTheOldMachine() {
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            for text in ["book a table for two", "go to those", "and then um", "yes"] {
                let rule = TurnVerdictRule.verdict(p: p, text: text)
                var old = capturing(nil)
                var new = capturing(.before)
                let a = old.handle(.turnVerdict(complete: rule.complete, stillMidClause: rule.stillMidClause))
                let b = new.handle(.turnVerdict(complete: rule.complete, stillMidClause: rule.stillMidClause,
                                                evidence: E(p: p, text: text, pauseSoFar: 0.4)))
                #expect(a == b, "p=\(p) \"\(text)\"")
                #expect(old.state == new.state)
                // …and whatever clock was armed ends the same way.
                for kind in [M.TimerKind.verdictHold, .silence] {
                    var o = old, n = new
                    #expect(o.handle(.timer(kind)) == n.handle(.timer(kind)), "p=\(p) \"\(text)\" \(kind)")
                }
            }
        }
    }

    /// Decide early and hold the reply: a plain "finished" starts the brain
    /// now, and the hold is what is left of the silence target.
    @Test func aConfidentFinishDecidesNowAndHoldsWhatIsLeft() {
        let policy = EndpointPolicy(decideAt: 0.5, unsureAt: 0.1, unsureWait: 0.7,
                                    holdBase: 1.2, holdPerDoubt: 0, waitsCountThePause: true)
        let plan = policy.plan(E(p: 0.97, text: "book a table for two", pauseSoFar: 0.4), onStall: false)
        #expect(plan.decideIn == 0)
        #expect(abs(plan.hold - 0.8) < 1e-9)
        #expect(plan.reason == .turnModel)
        var m = capturing(policy)
        let out = m.handle(.turnVerdict(complete: true, evidence: E(p: 0.97, text: "book a table for two", pauseSoFar: 0.4)))
        #expect(out.contains(.decided(.turnModel)))
        #expect(out.contains(where: { if case .holdReply(let s) = $0 { return abs(s - 0.8) < 1e-9 }; return false }))
    }

    /// Smart Turn's own 5 % point on eot-bench fires at p > 0.09 after 0.7 s:
    /// a middling score is "probably finished", not "mid-thought for 3 s".
    @Test func aMiddlingScoreWaitsTheSilenceNotTheCeiling() {
        let policy = EndpointPolicy(decideAt: 0.5, unsureAt: 0.1, unsureWait: 0.7,
                                    holdBase: 1.2, waitsCountThePause: true)
        let plan = policy.plan(E(p: 0.3, text: "book a table for two", pauseSoFar: 0.4), onStall: false)
        #expect(abs(plan.decideIn - 0.3) < 1e-9)          // 0.7 of silence, 0.4 already heard
        #expect(abs(plan.hold - 0.5) < 1e-9)              // 1.2 in all
        let low = policy.plan(E(p: 0.05, text: "book a table for two", pauseSoFar: 0.4), onStall: false)
        #expect(low.decideIn > 2)                          // under unsureAt: the old ceiling
    }

    /// The held reply after a clock: the plan's hold travels with the clock,
    /// and words that cancel the clock cancel it.
    @Test func thePlannedHoldTravelsWithItsClockAndWordsCancelBoth() {
        let policy = EndpointPolicy(decideAt: 0.5, unsureAt: 0.1, unsureWait: 0.9,
                                    holdBase: 1.4, waitsCountThePause: true)
        var m = capturing(policy)
        let armed = m.handle(.turnVerdict(complete: false, evidence: E(p: 0.3, text: "book a table", pauseSoFar: 0.4)))
        #expect(armed.contains(.armTimer(.silence, seconds: 0.5)))
        let fired = m.handle(.timer(.silence))
        // The turn model's decision after its wait — not a "ceiling" (review M8).
        #expect(fired.contains(.decided(.turnModel)))
        #expect(fired.contains(where: { if case .holdReply(let s) = $0 { return abs(s - 0.5) < 1e-9 }; return false }))

        var w = capturing(policy)
        _ = w.handle(.turnVerdict(complete: false, evidence: E(p: 0.3, text: "book a table", pauseSoFar: 0.4)))
        _ = w.handle(.wordsHeard(5))                      // they went on
        _ = w.handle(.speechEnded)
        let later = w.handle(.turnVerdict(complete: true))  // no evidence: the old rule
        #expect(later.contains(.holdReply(seconds: 0.8)))
    }

    @Test func aShortAnswerIsHeldLess() {
        let policy = EndpointPolicy(holdBase: 1.2, shortWords: 2, shortLess: 0.5, waitsCountThePause: true)
        let yes = policy.plan(E(p: 0.97, text: "yes", pauseSoFar: 0.3), onStall: false)
        let long = policy.plan(E(p: 0.97, text: "book a table for two", pauseSoFar: 0.3), onStall: false)
        #expect(abs(yes.hold - 0.4) < 1e-9)
        #expect(abs(long.hold - 0.9) < 1e-9)
    }

    // MARK: The fitted policy, on tapes

    private func tape(finishedAt p1: Double, resumesAfter gap: Double?, endP p2: Double) -> TurnTape {
        typealias Ev = TurnTape.Event
        var ev = [Ev(t: 0, .speechStarted), Ev(t: 0.3, .partial, "move my three"), Ev(t: 0.6, .partial, "move my three pm meeting")]
        ev.append(Ev(t: 0.9, .speechEnded))                          // the VAD, 0.3 s after the words
        var truth: TurnTape.Truth
        if let gap {
            let back = 0.6 + gap
            ev.append(Ev(t: back + 0.25, .speechStarted))
            ev.append(Ev(t: back + 0.4, .partial, "move my three pm meeting to friday"))
            ev.append(Ev(t: back + 0.9, .speechEnded))
            truth = .init(holds: [.init(start: 0.6, end: back)], end: .init(start: back + 0.6, end: back + 8))
        } else {
            truth = .init(holds: [], end: .init(start: 0.6, end: 8))
        }
        let probes = [TurnTape.Probe(t: 0.9, p: p1), TurnTape.Probe(t: (gap ?? 0) + 1.5, p: p2)]
        return TurnTape(id: "t", events: ev, probes: [TurnTape.key(tail: 0.3): probes], truth: truth,
                        duration: (gap ?? 0) + 9)
    }

    private func score(_ t: TurnTape, _ policy: EndpointPolicy?) -> EotScore.Turn {
        var tuning = VoiceMachine.Tuning()
        tuning.endpoint = policy
        return EotScore.score(t, PolicyReplay.run(t, PolicyReplay.Config(tuning: tuning)))
    }

    /// The owner's 64 of 108: "finished" p ≥ 0.94 at a breath after a clause
    /// that parses as complete, and he goes on 1–3 s later. The fitted policy
    /// releases the reply at ~1.45 s of quiet at p 0.96, so it covers breaths
    /// up to about that — this one, 0.95 s — and **not** the 1.5–3 s ones,
    /// which stay reply cut-offs (review M8; the continuation window still
    /// joins them if the brain's own latency outlasts the breath).
    @Test func aConfidentFinishAtABreathIsHeldPastTheBreath() {
        let t = tape(finishedAt: 0.96, resumesAfter: 0.95, endP: 0.97)
        let old = score(t, nil)
        let new = score(t, .fitted)
        #expect(old.commitCuts == 1)
        #expect(new.commitCuts == 0)
        #expect(new.continuations == 1)
    }

    /// Smart Turn at 0.3 on a real end: the old machine called it mid-thought
    /// and waited out a 3 s ceiling; the fitted policy starts the brain at
    /// once and lets the answer out at 2.1 s of quiet (1.4 + 1.0·(1 − 0.3)).
    @Test func aMiddlingScoreOnARealEndIsNotAThreeSecondWait() throws {
        let t = tape(finishedAt: 0.3, resumesAfter: nil, endP: 0.3)
        let old = try #require(score(t, nil).commitLatency)
        let new = try #require(score(t, .fitted).commitLatency)
        #expect(old > 3.0)
        #expect(abs(new - 2.1) < 0.01)
    }
}

/// 2026-09-29 20:47:21: "…how many different places are we doing this",
/// p=0.16, words that do not trail off — and the microphone stayed open
/// 6 s over silence. Low confidence on finished-looking words waits the 3 s
/// mid-thought ceiling from the pause; only dangling words wait six.
struct LowScoreFinishedWordsTests {

    @Test func aLowScoreOnWordsThatDoNotDangleWaitsThreeSecondsNotSix() {
        let e = EndpointPolicy.Evidence(p: 0.16, text: "how many different places are we doing this", pauseSoFar: 0.8)
        let plan = EndpointPolicy.shipped.plan(e, onStall: false)
        #expect(plan.reason == .ceiling)
        #expect(plan.decideIn < 3.0, "counted from the pause, not six from the verdict")
        #expect(plan.decideIn > 1.0)
    }

    @Test func wordsThatTrailOffStillWaitTheSixSecondCeiling() {
        let e = EndpointPolicy.Evidence(p: 0.16, text: "and then we need to", pauseSoFar: 0.8)
        let plan = EndpointPolicy.shipped.plan(e, onStall: false)
        #expect(plan.decideIn >= 6.0)
    }
}
