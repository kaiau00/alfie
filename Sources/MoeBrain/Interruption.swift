import Foundation

/// What an interruption means for the request that was already running.
///
/// Someone who talks over Moe mid-job is usually *amending* what they asked
/// for, not withdrawing it. Moe treated every interruption as a replacement:
/// the session was reset and the next turn carried only the new words, so a
/// five-part request corrected in one clause became a one-part request. The
/// literature has a name for it — **objective displacement**, "the model
/// pivots entirely to the interruption, abandoning the original task"
/// (EchoChain, arXiv 2604.16456, which measured no real-time voice model
/// above a 50% pass rate on this).
///
/// The default is therefore *amend*, for the reason the benchmark work and
/// the dialogue literature agree on: amending is reversible and replacing is
/// not. If Moe keeps the rest of the request and the person wanted it gone,
/// they say so and it is gone. If Moe drops it and they wanted it kept, they
/// have no way to know it was ever dropped — which is exactly what happened.
///
/// It is Levelt's well-formedness rule from 1983 in one sentence: a repair is
/// a graft onto the interrupted utterance, not a new one.
public enum Interruption {

    /// Phrases that really do withdraw what came before. Deliberately short:
    /// this list is the only thing standing between a correction and being
    /// treated as a replacement, and a false positive here silently discards
    /// the rest of somebody's request — the failure this whole type exists to
    /// stop. Anything not plainly an abandonment is an amendment.
    static let abandonCues = [
        "never mind", "nevermind", "forget it", "forget that", "forget all that",
        "scratch that", "scrap that", "cancel that", "stop that",
        "don't bother", "do not bother", "leave it", "drop it",
        "instead of all that", "start over", "start again", "new request",
    ]

    /// Does this utterance withdraw the standing request rather than change it?
    public static func abandons(_ text: String) -> Bool {
        let t = text.lowercased()
        return abandonCues.contains { t.contains($0) }
    }

    /// The sentence prefixed to the interrupting words, telling the model what
    /// to do with everything asked for before them.
    ///
    /// `heard` is what the person actually heard of the reply they cut off —
    /// the model needs it so it does not repeat a sentence they have already
    /// been told, and does not believe it finished saying something it did not.
    /// The sentence prefixed to a request the person spoke in two halves,
    /// when the first half had already gone to the model and been withdrawn.
    /// Unlike `note`, nothing stands: the fragment was never the request.
    public static func continuationNote() -> String {
        "(The person paused mid-sentence and you began answering the first half of what they"
        + " said; they heard none of it. That fragment was not their request — this is, whole:) "
    }

    public static func note(heard: String, saying: String) -> String {
        let heardPart = heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(You were interrupted before saying anything of your last reply; the user heard none of it."
            : "(You were interrupted; the user heard your last reply only up to: “\(heard.suffix(160))”."
        let standing = abandons(saying)
            ? " They are dropping what they asked for before this; do that instead, and let the rest go."
            : " Everything they asked you for before this still stands — what follows changes part of it,"
            + " it does not replace it. Carry on with the rest, and do not redo what is already done."
        return heardPart + standing + ") "
    }
}
