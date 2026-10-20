import Foundation

/// Scores the turn bench's corpus (research-eval-harness.md §3.5) against its
/// truth — the corpus's word timings, never anything Moe decided.
///
/// **Turns** (Moe listening) are scored by `EotScore`, eot-bench's
/// definitions: the cut-off rate over the pauses the person went on after,
/// and the latency from the true end to the reply becoming audible (with an
/// instant brain: the pipeline's own number). A turn the machine never
/// decided at all — the file ran out first — is a **missed turn**.
///
/// **Replies** (Moe talking) are scored here:
/// - **false barge-in**: the reply paused or stopped when nobody had said
///   anything Moe should stop for — noise, echo, another voice, or a
///   backchannel. Counted per 10 minutes of Moe's audio that had no real
///   interruption in it (`exposure`);
/// - **false duck**: the same for the duck, which is cheap — reported, not gated;
/// - **missed barge-in**: a stop word or a real interruption, and the reply
///   still not paused `missWindow` (2 s) after its first word;
/// - **stop latency**: the first word of a real interruption → the pause.
///   **Duck latency**: → the duck;
/// - **backchannel stops**: "mm-hm" or "yeah" over the reply, and it paused.
///
/// A reply the machine falsely paused before the person spoke cannot say
/// anything about their interruption (the timeline diverged there), so its
/// interruption is left out of the missed count rather than counted either way.
public enum CorpusScore {

    public static let missWindow = 2.0

    public struct ReplyTurn: Equatable, Sendable {
        /// Seconds of reply audible with no real interruption in them, up to
        /// the first pause.
        public var exposure = 0.0
        public var falseStop = false
        public var falseDucks = 0
        public var real = false
        public var backchannel = false
        public var backchannelStopped = false
        /// Nil when not a real interruption, or when it cannot be scored.
        public var missed: Bool?
        public var stopLatency: Double?
        public var duckLatency: Double?
    }

    public static func score(_ s: TurnCorpus.Scenario, _ r: BargeReplay.Result,
                             missWindow: Double = missWindow) -> ReplyTurn {
        var out = ReplyTurn()
        guard let reply = s.reply else { return out }
        let inter = s.interjection
        out.real = inter?.isReal ?? false
        out.backchannel = inter?.kind == "backchannel"
        let realAt = out.real ? inter!.start : Double.infinity
        let firstPause = r.pauses.first
        let quiet = min(firstPause ?? .infinity, realAt, reply.end)
        out.exposure = max(0, quiet - reply.start)
        out.falseDucks = r.ducks.filter { $0 < quiet - 1e-9 }.count
        if let p = firstPause, p < realAt - 1e-9 {
            out.falseStop = true
            if out.backchannel, let inter, p >= inter.start - 1e-9 { out.backchannelStopped = true }
        }
        guard out.real, let inter, !out.falseStop else { return out }
        if let d = r.ducks.first(where: { $0 >= inter.start - 1e-9 }) { out.duckLatency = d - inter.start }
        if let p = firstPause, p - inter.start <= missWindow + 1e-9 {
            out.missed = false
            out.stopLatency = p - inter.start
        } else if reply.end >= inter.start + missWindow - 1e-9 {
            out.missed = true
        }
        // Otherwise the reply ended inside the window on its own: unscored.
        return out
    }

    public struct ReplySummary: Equatable, Sendable {
        public var scenarios = 0
        public var moeMinutes = 0.0
        public var falseStops = 0
        public var falseStopsPer10Min = 0.0
        public var falseDucksPer10Min = 0.0
        public var real = 0
        public var missed = 0
        public var missedRate = 0.0
        public var stopP50 = 0.0
        public var stopP90 = 0.0
        public var duckP50 = 0.0
        public var backchannels = 0
        public var backchannelStops = 0
    }

    public static func summarize(_ turns: [ReplyTurn]) -> ReplySummary {
        var s = ReplySummary()
        s.scenarios = turns.count
        let exposure = turns.reduce(0) { $0 + $1.exposure }
        s.moeMinutes = exposure / 60
        s.falseStops = turns.filter(\.falseStop).count
        let ducks = turns.reduce(0) { $0 + $1.falseDucks }
        if exposure > 0 {
            s.falseStopsPer10Min = Double(s.falseStops) / exposure * 600
            s.falseDucksPer10Min = Double(ducks) / exposure * 600
        }
        let scored = turns.compactMap(\.missed)
        s.real = scored.count
        s.missed = scored.filter { $0 }.count
        s.missedRate = scored.isEmpty ? 0 : Double(s.missed) / Double(scored.count)
        let stops = turns.compactMap(\.stopLatency).sorted()
        s.stopP50 = EotScore.quantile(stops, 0.5)
        s.stopP90 = EotScore.quantile(stops, 0.9)
        s.duckP50 = EotScore.quantile(turns.compactMap(\.duckLatency).sorted(), 0.5)
        s.backchannels = turns.filter(\.backchannel).count
        s.backchannelStops = turns.filter(\.backchannelStopped).count
        return s
    }

    /// A turn, scored: `EotScore`'s reading plus whether it was decided at all.
    public struct Turn: Equatable, Sendable {
        public var eot: EotScore.Turn
        public var missed: Bool
    }

    public static func score(_ tape: TurnTape, _ r: PolicyReplay.Result,
                             _ o: EotScore.Options = EotScore.Options()) -> Turn {
        let eot = EotScore.score(tape, r, o)
        let endAt = tape.truth?.end.start ?? .infinity
        let decided = r.decisions.contains { $0.t >= endAt - 1e-9 }
        return Turn(eot: eot, missed: tape.truth != nil && !decided)
    }

    public struct TurnSummary: Equatable, Sendable {
        public var eot: EotScore.Summary
        public var missed = 0
    }

    public static func summarize(_ turns: [Turn]) -> TurnSummary {
        // Latency is over the turns Moe answered; a missed one has no latency
        // to speak of and is counted on its own.
        let answered = turns.filter { !$0.missed }.map(\.eot)
        var eot = EotScore.summarize(answered)
        // The cut-offs are every turn's, answered or not.
        let all = EotScore.summarize(turns.map(\.eot))
        eot.holds = all.holds
        eot.decisionCutRate = all.decisionCutRate
        eot.commitCutRate = all.commitCutRate
        eot.turns = turns.count
        return TurnSummary(eot: eot, missed: turns.filter(\.missed).count)
    }

    /// Wilson's 95% interval for k of n — a rate from a few hundred cases
    /// is not a point.
    public static func wilson(_ k: Int, _ n: Int) -> (lo: Double, hi: Double) {
        guard n > 0 else { return (0, 1) }
        let z = 1.96, p = Double(k) / Double(n), nn = Double(n)
        let denom = 1 + z * z / nn
        let centre = (p + z * z / (2 * nn)) / denom
        let half = z * ((p * (1 - p) / nn + z * z / (4 * nn * nn)).squareRoot()) / denom
        return (max(0, centre - half), min(1, centre + half))
    }
}
