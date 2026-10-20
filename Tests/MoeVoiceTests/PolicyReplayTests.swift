import Foundation
import Testing
@testable import MoeVoice

/// The Tier-0 replay against incidents with a known right answer — the
/// "seed tapes" of research-eval-harness.md §3.2. Each is a fix that is on
/// main; each test must go red when that fix is reverted, which is what
/// shows the replay reproduces the machine rather than agreeing with itself.
struct PolicyReplayTests {

    typealias E = TurnTape.Event

    /// Words arriving one at a time, as the streaming recogniser writes them.
    private func words(_ text: String, from start: Double, every step: Double) -> [E] {
        var out: [E] = []
        var so = ""
        for (i, w) in text.split(separator: " ").enumerated() {
            so += (so.isEmpty ? "" : " ") + w
            out.append(E(t: start + Double(i) * step, .partial, so))
        }
        return out
    }

    private func tape(_ events: [E], p: [(Double, Double)], truth: TurnTape.Truth? = nil,
                      duration: Double) -> TurnTape {
        TurnTape(id: "t", events: events,
                 probes: [TurnTape.key(tail: 0.3): p.map { TurnTape.Probe(t: $0.0, p: $0.1) }],
                 truth: truth, duration: duration)
    }

    /// 2026-09-07 01:29:59Z: "Actually, I want you to actually go to those"
    /// — p=0.96, taken at once, cut mid-request. The dangler holds a
    /// "finished" verdict for `verdictHoldSeconds`, and the person going on
    /// inside it keeps the turn.
    @Test func aFinishedVerdictOnADanglerWaitsForTheRest() throws {
        var ev = [E(t: 0.0, .speechStarted)]
        ev += words("actually i want you to actually go to those", from: 0.3, every: 0.2)
        ev.append(E(t: 2.3, .speechEnded))                      // the VAD, 0.3 s after "those"
        ev.append(E(t: 2.6, .speechStarted))                    // "…the files" 0.6 s later
        ev.append(E(t: 2.8, .partial, "actually i want you to actually go to those files"))
        ev.append(E(t: 3.0, .partial, "actually i want you to actually go to those files please"))
        ev.append(E(t: 3.6, .speechEnded))
        let t = tape(ev, p: [(2.3, 0.96), (3.6, 0.97)], duration: 8)
        let r = PolicyReplay.run(t, PolicyReplay.Config())
        #expect(r.decisions.count == 1)
        let first = try #require(r.decisions.first)
        #expect(first.t > 3.6, "decided at \(first.t), inside the pause after \"those\"")
        #expect(first.text.hasSuffix("please"))
    }

    /// The 53 s capture of 2026-09-07 11:48Z: a fan kept the VAD "in speech"
    /// for good, so no pause was ever reported and the turn model was never
    /// asked. The word stall asks it anyway.
    @Test func wordsStoppingInNoiseEndTheTurnWithoutAVadPause() throws {
        var ev = [E(t: 0.0, .speechStarted)]
        ev += words("can you turn the lights off in the kitchen", from: 0.3, every: 0.25)
        let lastWord = 0.3 + 8 * 0.25          // nine words
        let t = tape(ev, p: [(lastWord + 0.5, 0.93)], duration: 60)
        let r = PolicyReplay.run(t, PolicyReplay.Config())
        let d = try #require(r.decisions.first)
        #expect(d.reason == .stall)
        // 1.3 s of no words, then the model's answer (≈40 ms).
        #expect(abs(d.t - (lastWord + 1.3 + 0.04)) < 0.01)
    }

    /// 34.7 s of wordless noise held a capture open on 2026-09-07. Sound with
    /// no word for 3.5 s ends the capture silently: no turn at all.
    @Test func soundWithNoWordsIsNotATurn() {
        let t = tape([E(t: 1.0, .speechStarted)], p: [], duration: 40)
        let r = PolicyReplay.run(t, PolicyReplay.Config())
        #expect(r.decisions.isEmpty)
        #expect(r.wordlessEnds.count == 1)
        #expect(abs((r.wordlessEnds.first ?? 0) - 4.5) < 0.01)
    }

    /// A stale verdict is dropped the way the engine drops it: the person
    /// spoke again (a VAD edge) before the answer came back.
    @Test func aVerdictOverTakenByAVadEdgeIsDropped() {
        var ev = [E(t: 0.0, .speechStarted)]
        ev += words("send it to", from: 0.2, every: 0.2)
        ev.append(E(t: 1.0, .speechEnded))
        ev.append(E(t: 1.02, .speechStarted))                   // inside the 40 ms inference
        let t = tape(ev, p: [(1.0, 0.99)], duration: 1.5)
        let r = PolicyReplay.run(t, PolicyReplay.Config())
        #expect(r.verdicts.isEmpty)
    }

    /// The scorer: a decision inside a pause the person went on after is a
    /// cut-off; with the reply held past the moment they are heard again it
    /// is only a continuation. The true end's latency is measured from the
    /// end of the last word.
    @Test func theScorerTellsACutFromAContinuation() throws {
        var ev = [E(t: 0.0, .speechStarted)]
        ev += words("book me a table", from: 0.2, every: 0.2)     // last word 0.8
        ev.append(E(t: 1.2, .speechEnded))
        ev.append(E(t: 1.9, .speechStarted))                      // went on at 1.7
        ev.append(E(t: 2.1, .partial, "book me a table for"))
        ev.append(E(t: 2.3, .partial, "book me a table for two"))
        ev.append(E(t: 2.8, .speechEnded))
        let truth = TurnTape.Truth(holds: [.init(start: 0.9, end: 1.7)], end: .init(start: 2.5, end: 6))
        let t = tape(ev, p: [(1.2, 0.97), (2.8, 0.98)], truth: truth, duration: 6)

        var cfg = PolicyReplay.Config()
        cfg.tuning.replyFloorSeconds = 0
        let bare = EotScore.score(t, PolicyReplay.run(t, cfg))
        #expect(bare.holds == 1)
        #expect(bare.decisionCuts == 1)
        #expect(bare.commitCuts == 1)

        cfg.tuning.replyFloorSeconds = 0.8                        // held past the 1.9 onset
        let held = EotScore.score(t, PolicyReplay.run(t, cfg))
        #expect(held.decisionCuts == 1)
        #expect(held.commitCuts == 0)
        #expect(held.continuations == 1)
        let latency = try #require(held.decisionLatency)
        #expect(abs(latency - (2.84 - 2.5)) < 0.01)
    }
}
