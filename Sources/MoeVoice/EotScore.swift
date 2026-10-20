import Foundation

/// Scores a `PolicyReplay` against a tape's ground truth the way LiveKit's
/// eot-bench scores an end-of-turn model (github.com/livekit/eot-bench,
/// `eot_harness/metrics.py`), adapted to what Moe actually does:
///
/// - **cut-off rate**: of the pauses the person went on after (`holds`,
///   0.2–5.0 s, eot-bench's own filter), the share Moe answered in;
/// - **latency**: from the true end of the turn to Moe's answer.
///
/// Two readings of "answered", because Moe starts the brain at the decision
/// and holds the voice (`VoiceMachine.Action.holdReply`):
///
/// - *decision*: the machine decided inside the pause — eot-bench's own
///   definition, and the one the published table compares against;
/// - *commit*: the reply would have become audible — at the decision plus
///   the longer of the hold and the brain's own latency — before Moe could
///   know the person had gone on. This is the one a person feels. A
///   decision the person talks through before the commit is a
///   continuation (both halves go to the brain as one turn), not a cut-off.
public enum EotScore {

    public struct Options: Sendable {
        public var minHold = 0.2
        public var maxHold = 5.0
        /// How long the brain takes to have audio after a decision. 0 is the
        /// pipeline's own number: the worst case, an instant brain.
        public var brainSeconds = 0.0
        /// What tells Moe the person went on, for a reply that is being held:
        /// the first VAD onset after the pause (the engine holds the reply
        /// while a continuation onset waits on its words), or only the first
        /// new word (a host that does not).
        public var resumeByOnset = true
        public init() {}
    }

    public struct Turn: Equatable, Sendable {
        public var holds = 0
        public var decisionCuts = 0
        public var commitCuts = 0
        /// Decided inside a pause, and the person went on before the reply
        /// could be heard: the two halves are joined.
        public var continuations = 0
        /// True end → decision, and → the reply becoming audible.
        public var decisionLatency: Double?
        public var commitLatency: Double?
        /// The reason the turn's end was decided with.
        public var endReason: VoiceMachine.EndReason?
        /// For each decision taken inside a pause the person went on after:
        /// how long the brain ran on the fragment before Moe could know they
        /// had (the first onset or word after the pause). Long enough and a
        /// fragment's turn can reach a tool call (review M1).
        public var fragmentRuns: [Double] = []
    }

    public static func score(_ tape: TurnTape, _ result: PolicyReplay.Result,
                             _ o: Options = Options()) -> Turn {
        var turn = Turn()
        guard let truth = tape.truth else { return turn }
        let scored = truth.holds.filter { $0.duration >= o.minHold - 1e-9 && $0.duration <= o.maxHold + 1e-9 }
        turn.holds = scored.count

        func firstEvent(after t: Double, _ kinds: Set<TurnTape.Kind>) -> Double {
            tape.events.first { $0.t >= t - 1e-9 && kinds.contains($0.kind) }?.t ?? .infinity
        }
        var cutHolds = Set<Int>()        // index into `scored`
        var commitCutHolds = Set<Int>()
        for d in result.decisions {
            let commit = d.t + max(d.replyHold, o.brainSeconds)
            if d.t >= truth.end.start - 1e-9 {
                if turn.decisionLatency == nil {
                    turn.decisionLatency = d.t - truth.end.start
                    turn.commitLatency = commit - truth.end.start
                    turn.endReason = d.reason
                }
                continue
            }
            // The last pause that began before the decision.
            guard let h = scored.lastIndex(where: { $0.start <= d.t + 1e-9 }) else {
                // Before any scored pause: inside speech, or a pause too short
                // to be scored — a cut all the same, not one eot-bench counts.
                continue
            }
            let hold = scored[h]
            let heardAgain = firstEvent(after: hold.end, [.partial])
            let noticed = o.resumeByOnset ? min(heardAgain, firstEvent(after: hold.end, [.speechStarted]))
                                          : heardAgain
            // A decision after the person was heard again is mid-speech; it
            // still took the turn away from them, at the pause before it.
            cutHolds.insert(h)
            turn.fragmentRuns.append(max(0, noticed - d.t))
            if commit < noticed || d.t >= heardAgain { commitCutHolds.insert(h) } else { turn.continuations += 1 }
        }
        turn.decisionCuts = cutHolds.count
        turn.commitCuts = commitCutHolds.count
        if turn.decisionLatency == nil {
            // Never decided: the whole tail was waited out.
            turn.decisionLatency = tape.duration - truth.end.start
            turn.commitLatency = turn.decisionLatency
        }
        return turn
    }

    public struct Summary: Equatable, Sendable {
        public var turns = 0
        public var holds = 0
        public var decisionCutRate = 0.0
        public var commitCutRate = 0.0
        public var continuationsPerTurn = 0.0
        public var meanDecisionLatency = 0.0
        public var meanCommitLatency = 0.0
        public var p50CommitLatency = 0.0
        public var p90CommitLatency = 0.0
        /// Turns whose end was decided by a clock that waits out a
        /// "not finished" (`ceiling`) or the cap.
        public var ceilingEnds = 0
        public var reasons: [String: Int] = [:]
    }

    public static func summarize(_ turns: [Turn]) -> Summary {
        var s = Summary()
        s.turns = turns.count
        s.holds = turns.reduce(0) { $0 + $1.holds }
        guard s.turns > 0 else { return s }
        if s.holds > 0 {
            s.decisionCutRate = Double(turns.reduce(0) { $0 + $1.decisionCuts }) / Double(s.holds)
            s.commitCutRate = Double(turns.reduce(0) { $0 + $1.commitCuts }) / Double(s.holds)
        }
        s.continuationsPerTurn = Double(turns.reduce(0) { $0 + $1.continuations }) / Double(s.turns)
        let d = turns.compactMap(\.decisionLatency)
        let c = turns.compactMap(\.commitLatency).sorted()
        s.meanDecisionLatency = d.isEmpty ? 0 : d.reduce(0, +) / Double(d.count)
        s.meanCommitLatency = c.isEmpty ? 0 : c.reduce(0, +) / Double(c.count)
        s.p50CommitLatency = quantile(c, 0.5)
        s.p90CommitLatency = quantile(c, 0.9)
        for t in turns {
            let r = t.endReason?.rawValue ?? "none"
            s.reasons[r, default: 0] += 1
            if t.endReason == .ceiling || t.endReason == .cap { s.ceilingEnds += 1 }
        }
        return s
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[i]
    }
}
