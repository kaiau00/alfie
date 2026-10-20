import Foundation

/// What a Smart Turn probability and the words so far say about a pause:
/// finished, or not — and when not, whether both signals agree that the
/// person is mid-clause.
///
/// It lived inline in `VoiceEngine.askTurnModel` until the Tier-0 replay
/// (`PolicyReplay`) needed the very same rule: a replay that re-implements
/// the verdict is a replay of a copy, and the first time the two drift the
/// sweep tunes something the app does not run. One rule, two readers.
public enum TurnVerdictRule {

    /// Above this the audio model says "finished". The reference's own value
    /// (`SmartTurnDetector.threshold` carries the history of why).
    public static let threshold: Double = 0.5
    /// Below this the model is saying "mid-thought", not merely unsure.
    public static let stronglyUnfinished: Double = 0.35
    /// A "finished" under this, on words that end on a dangler ("…and
    /// then"), is overruled: measured on a real dictation, p=0.64 on exactly
    /// that ending.
    public static let weakFinished: Double = 0.8

    public struct Verdict: Equatable, Sendable {
        public let complete: Bool
        public let stillMidClause: Bool
    }

    public static func verdict(p: Double, text: String) -> Verdict {
        let dangling = TurnPolicy.completeness(of: text) == .incomplete
        var complete = p > threshold
        if complete, p < weakFinished, dangling { complete = false }
        return Verdict(complete: complete, stillMidClause: dangling || p < stronglyUnfinished)
    }
}
