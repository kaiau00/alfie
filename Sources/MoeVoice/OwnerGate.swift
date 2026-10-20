import Foundation

/// Is this voice clearly not the owner's? The one check that rejects the TV
/// and other people in the room (research-noise.md §3, PLAN.md Step 1.4):
/// a VAD, a word gate and a denoiser all pass a television's dialogue,
/// because it *is* speech, and words.
///
/// Conservative on purpose, because the cost of being wrong is refusing the
/// person the whole thing exists for:
/// - only "clearly not": under `rejectBelow`, far under anything the owner
///   has scored (17 of his turns, 0.51 at the lowest; Moe's own voice 0.17);
/// - never without an enrolment — a guest at a Mac whose owner has not
///   taught it their voice can always talk;
/// - never when the words name Moe — a second person joins a conversation by
///   asking for it;
/// - never on under a second of speech, where the embedding is noise.
///
/// Held keys never come here: whoever holds the key is the person asking.
public enum OwnerGate {

    public enum Verdict: Equatable, Sendable {
        /// Clearly somebody else: drop it.
        case notOwner
        /// The owner, or nothing measured, or a case the gate never judges.
        case letThrough
    }

    /// A quarter below the owner's lowest measured score (0.51), and over
    /// Moe's own voice (0.17) — which the echo checks already catch.
    public static let rejectBelow = 0.25
    /// The embedder's own floor (`OwnerVoice.minSeconds`).
    public static let minSeconds = 1.0

    /// What the host does with a verdict.
    public enum Outcome: String, Equatable, Sendable {
        /// Dropped (enforcing).
        case drop
        /// Would have been dropped: logged with its score, nothing done.
        case shadow
        case pass
    }

    /// Enforcing is off by default (review H3): 0.25 was chosen from the
    /// owner's whole turns against his enrolment, and nobody has measured a
    /// second of speech against a session's anchor, or the other side — the
    /// TV, other people. Until the owner's logged scores show a safe line,
    /// the gate only writes down what it would have done.
    ///
    /// Never on the rest of a turn the session already accepted (the person
    /// going on after a pause): there a wrong "not you" throws away the
    /// second half of a request and answers the first.
    public static func outcome(_ v: Verdict, enforce: Bool, continuation: Bool) -> Outcome {
        guard v == .notOwner, !continuation else { return .pass }
        return enforce ? .drop : .shadow
    }

    public static func verdict(score: Double?, enrolled: Bool, named: Bool, seconds: Double) -> Verdict {
        guard enrolled, !named, seconds >= minSeconds, let score else { return .letThrough }
        return score < rejectBelow ? .notOwner : .letThrough
    }
}
