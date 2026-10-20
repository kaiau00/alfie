import Foundation

/// Turns a stream of wake-head scores into "it was said" decisions.
/// VOICE-PLAN.md §4.1.
///
/// The head scores a two-second window every 80 ms while the VAD hears
/// speech. Its positives were trained end-aligned, so a real "Hey Moe"
/// scores high on several consecutive windows as the phrase sits at the
/// tail. A phrase that merely *starts* like it ("hey mobile") also scores
/// high — for the few windows in which the rest has not yet arrived,
/// after which the score falls. Measured on LiveKit's own fixture: the
/// negative peaks at 0.88 for four strides while only its first second
/// is in the window, and is under 0.2 once all of it is. So one hit is a
/// guess; a run of them is a detection — unless a single window is
/// emphatic, which a clear phrase in a quiet room produces and should
/// not be made to wait. The run length and both thresholds come from the
/// trained head's sidecar, set from the bench.
///
/// After a detection the head is ignored for a while: the phrase is
/// still inside the window on the next runs and would fire again.
public struct WakePolicy: Equatable, Sendable {

    public var threshold: Float
    /// A single window this sure fires on its own.
    public var strongThreshold: Float
    /// Consecutive windows at or above `threshold` that make a detection.
    public var requiredHits: Int
    public var refractorySeconds: Double
    /// Two hits must be this close to count as consecutive (the head runs
    /// every 80 ms; a gap means the VAD gated it off in between).
    public var consecutiveWithinSeconds: Double

    private var run = 0
    private var lastHitAt: Double?
    private var firedAt: Double?

    public init(threshold: Float = 0.5, strongThreshold: Float? = nil, requiredHits: Int = 2,
                refractorySeconds: Double = 2.0, consecutiveWithinSeconds: Double = 0.25) {
        self.threshold = threshold
        // High by default: the partial-phrase windows above reach 0.88.
        // A strong threshold at or below the threshold would make every
        // hit fire; that is not a setting, it is a mistake — ignored. At
        // or above 1 means "never on one window".
        let strong = strongThreshold ?? 0.95
        self.strongThreshold = strong > threshold ? min(strong, 2) : max(0.95, threshold)
        self.requiredHits = max(1, requiredHits)
        self.refractorySeconds = refractorySeconds
        self.consecutiveWithinSeconds = consecutiveWithinSeconds
    }

    /// One head result. True when the name was said.
    public mutating func observe(score: Float, at t: Double) -> Bool {
        if let fired = firedAt, t - fired < refractorySeconds { return false }
        guard score >= threshold else { run = 0; lastHitAt = nil; return false }
        let consecutive = lastHitAt.map { t - $0 <= consecutiveWithinSeconds } ?? false
        run = consecutive ? run + 1 : 1
        lastHitAt = t
        if score >= strongThreshold || run >= requiredHits {
            firedAt = t
            run = 0
            lastHitAt = nil
            return true
        }
        return false
    }

    /// The same policy at another threshold: the run length, the emphatic
    /// window and the timings stay as the sidecar set them. This is how a
    /// per-Mac threshold is built — from the shipped policy, every time —
    /// so the head and the calibration that picks the number cannot
    /// resolve `strong` two different ways.
    public func withThreshold(_ t: Float) -> WakePolicy {
        WakePolicy(threshold: t, strongThreshold: strongThreshold, requiredHits: requiredHits,
                   refractorySeconds: refractorySeconds, consecutiveWithinSeconds: consecutiveWithinSeconds)
    }

    /// Back to quiet — the head was switched off, or the owner changed.
    /// The refractory stays: the phrase that just fired is still inside
    /// the window if the head comes straight back.
    public mutating func reset() {
        run = 0
        lastHitAt = nil
    }
}
