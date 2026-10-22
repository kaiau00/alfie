import Foundation

/// Picking the wake threshold for one Mac from the person's own clips.
///
/// The head ships with the threshold a bench found on synthesised speech
/// and one owner's held-out recordings — 0.95, which catches about two
/// thirds of that owner's "Hey Moe"s. Whether it is right for *this*
/// voice in *this* room is a measurement nobody had made, because the
/// only way to make it was a Terminal command and a retrain. This is the
/// measurement, and it never touches the model: each clip has already
/// been scored window by window, and the question is only which line
/// through those scores keeps the near misses out while letting the
/// most real ones in.
///
/// Pure. The traces come from the same `WakePolicy` replay the pipeline
/// runs, so a clip that "fires here" fires in the app.
public enum WakeCalibration {

    /// One head score and the audio time it was taken at — what the
    /// pipeline's probe reports, and everything the policy looks at.
    public struct Sample: Equatable, Sendable {
        public var time: Double
        public var score: Float
        public init(time: Double, score: Float) { self.time = time; self.score = score }
    }

    /// How one policy did on the clips.
    public struct Tally: Equatable, Sendable {
        /// Clips with the name in them, and how many the policy fired on.
        public var positives: Int
        public var caught: Int
        /// Clips without it (near misses, ordinary speech), and how many
        /// fired anyway.
        public var confusables: Int
        public var falseAccepts: Int
        public init(positives: Int, caught: Int, confusables: Int, falseAccepts: Int) {
            self.positives = positives; self.caught = caught
            self.confusables = confusables; self.falseAccepts = falseAccepts
        }
    }

    /// The threshold chosen, and the tallies either side of the change.
    public struct Pick: Equatable, Sendable {
        public var threshold: Float
        public var after: Tally
        public var before: Tally
        public init(threshold: Float, after: Tally, before: Tally) {
            self.threshold = threshold; self.after = after; self.before = before
        }
    }

    /// The thresholds tried, a hundredth at a time up to just under
    /// certain. `pick` never goes below `lowestThreshold(for:)` — the eight near
    /// misses cannot measure what a room does below the number the bench
    /// measured hours of.
    public static let candidates: [Float] = stride(from: 20, through: 99, by: 1).map { Float($0) / 100 }

    /// The lowest threshold a pick may choose: 0.5, or the shipped
    /// threshold when the head ships below that. Heads differ in how sure
    /// they sound — v5 fired at 0.95, v6 (2026-09-23) peaks around 0.85 and
    /// ships at 0.28 — so a fixed floor of 0.5 would leave a low-shipping
    /// head nothing to choose but its own number and, worse, nothing it
    /// could reach.
    public static func lowestThreshold(for shipped: WakePolicy) -> Float {
        min(0.5, shipped.threshold)
    }

    /// Does a threshold measured for one head apply to the head loaded now?
    /// Only to the same one. A number picked on one model's scores is
    /// meaningless on another's: v5's 0.9 on v6, whose scores stop around
    /// 0.85, would never wake. `head` is the sidecar's `trained` stamp; a
    /// tuning written before tunings carried one (nil) applies only to a
    /// head that has none either.
    public static func tuningApplies(tunedFor: String?, head: String?) -> Bool {
        tunedFor == head
    }

    /// Would this policy fire on this clip? A fresh policy per clip: each
    /// is its own recording, with a lead-in before it.
    public static func fires(_ trace: [Sample], policy: WakePolicy) -> Bool {
        var p = policy
        p.reset()
        for s in trace where p.observe(score: s.score, at: s.time) { return true }
        return false
    }

    public static func tally(positives: [[Sample]], confusables: [[Sample]], policy: WakePolicy) -> Tally {
        Tally(positives: positives.count,
              caught: positives.filter { fires($0, policy: policy) }.count,
              confusables: confusables.count,
              falseAccepts: confusables.filter { fires($0, policy: policy) }.count)
    }

    /// The threshold for this Mac.
    ///
    /// Never fewer of the person's own "Hey Moe"s than the threshold in
    /// force catches now, and at least one; among those, the fewest false
    /// accepts on the near misses; then the most caught; and among ties
    /// the *highest* threshold — a lower one buys nothing on these clips
    /// and costs an unmeasured amount on everything the clips are not.
    ///
    /// The floor is there because "fewest false accepts first" on its own
    /// has a degenerate answer: a threshold nothing reaches has none, and
    /// catches nothing. Measured on synthesised voices, where four of the
    /// eight near misses scored above most of the names, it chose exactly
    /// that — 0 of 12 — over the 8 of 12 it started with.
    ///
    /// - Parameters:
    ///   - shipped: the sidecar's policy; every candidate is this at
    ///     another threshold (`withThreshold`), so `strong` and the run
    ///     length are the ones the head was benched with.
    ///   - current: what the pipeline is running now — the shipped policy,
    ///     or an earlier pick. "Before" is measured against this, and it
    ///     is always among the candidates.
    /// - Returns: nil when there is nothing to measure — no clip with the
    ///   name in it, or none that any threshold catches.
    public static func pick(positives: [[Sample]], confusables: [[Sample]],
                            shipped: WakePolicy, current: WakePolicy,
                            candidates: [Float] = candidates) -> Pick? {
        guard !positives.isEmpty else { return nil }
        let before = tally(positives: positives, confusables: confusables, policy: current)
        let lowest = lowestThreshold(for: shipped)
        var tried = Set(candidates.filter { $0 >= lowest })
        tried.insert(current.threshold)
        var best: (threshold: Float, tally: Tally)?
        for t in tried.sorted() {
            let tally = tally(positives: positives, confusables: confusables, policy: shipped.withThreshold(t))
            guard tally.caught >= max(1, before.caught) else { continue }
            guard let b = best else { best = (t, tally); continue }
            // `>=` on the last key: ascending order, so an equal result at
            // a higher threshold replaces the lower one.
            if tally.falseAccepts < b.tally.falseAccepts
                || (tally.falseAccepts == b.tally.falseAccepts && tally.caught >= b.tally.caught) {
                best = (t, tally)
            }
        }
        guard let best else { return nil }
        return Pick(threshold: best.threshold, after: best.tally, before: before)
    }

    // MARK: - In words

    /// "11 of 12", "all 12".
    static func caughtPhrase(_ n: Int, of total: Int) -> String {
        n == total && total > 1 ? "all \(total)" : "\(n) of \(total)"
    }

    /// "none of the 8", "1 of the 8", "all 8".
    static func falsePhrase(_ n: Int, of total: Int) -> String {
        if n == 0 { return "none of the \(total)" }
        if n == total && total > 1 { return "all \(total)" }
        return "\(n) of the \(total)"
    }

    /// The result, for the person who just did the recording.
    ///
    /// "Moe now catches 11 of 12 of your “Hey Moe”s and none of the 8
    /// near misses. Before: 8 of 12 and 2." When nothing changed, it says
    /// that rather than announcing an improvement of zero.
    public static func summary(_ pick: Pick, changed: Bool) -> String {
        let a = pick.after, b = pick.before
        let caught = "\(caughtPhrase(a.caught, of: a.positives)) of your “Hey Alfie”\(a.positives == 1 ? "" : "s")"
        let misses = a.confusables > 0
            ? " and \(falsePhrase(a.falseAccepts, of: a.confusables)) near miss\(a.confusables == 1 ? "" : "es")"
            : ""
        guard changed else {
            return "Alfie already catches \(caught)\(misses) — the setting it had is the best one for this Mac, so nothing changed."
        }
        var before = "Before: \(caughtPhrase(b.caught, of: b.positives))"
        if b.confusables > 0 { before += b.falseAccepts == 0 ? " and none" : " and \(b.falseAccepts)" }
        return "Alfie now catches \(caught)\(misses). \(before)."
    }
}
