import Foundation

/// Word error rate: the number the whole speech pipeline is actually judged
/// on, and until now the one thing Moe could not tell you about itself.
///
/// "Better dictation" is otherwise an argument about anecdotes. WER makes it
/// a measurement — run the same clips before and after a change and the
/// answer is a number, not a feeling. `Moe --stt-test <audio>` uses it
/// whenever a reference transcript sits beside the audio.
///
/// Standard definition: Levenshtein distance over *words*, divided by the
/// number of words in the reference. Substitutions, deletions and insertions
/// each count once; a rate above 1.0 is possible and means the engine wrote
/// more wrong words than the reference had words at all.
public enum WordErrorRate {

    public struct Score: Sendable, Equatable {
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        /// Words in the reference. Zero when the reference was empty, in
        /// which case `rate` is 0 for an empty guess and 1 for anything else
        /// rather than a division by zero.
        public let referenceWords: Int

        public var errors: Int { substitutions + deletions + insertions }
        public var rate: Double {
            guard referenceWords > 0 else { return errors == 0 ? 0 : 1 }
            return Double(errors) / Double(referenceWords)
        }
        /// The share of reference words that came through right. The number
        /// worth reading when WER is above 1.
        public var accuracy: Double { max(0, 1 - rate) }
    }

    /// One score over a whole clip set.
    ///
    /// Errors and words are pooled before dividing — *not* the mean of the
    /// per-clip rates. The two differ whenever the clips are different
    /// lengths, and the mean flatters a set by letting a clean six-word clip
    /// cancel out a bad sixty-word one. Pooled is the standard, and the one
    /// that answers "of everything I said, what fraction came out wrong".
    public static func total(_ scores: [Score]) -> Score {
        Score(substitutions: scores.reduce(0) { $0 + $1.substitutions },
              deletions: scores.reduce(0) { $0 + $1.deletions },
              insertions: scores.reduce(0) { $0 + $1.insertions },
              referenceWords: scores.reduce(0) { $0 + $1.referenceWords })
    }

    /// Compare a transcript against a reference.
    ///
    /// Both sides are normalised first — case folded, punctuation dropped,
    /// whitespace collapsed — because a WER that counts "Friday." against
    /// "Friday" as an error measures the punctuation rules rather than the
    /// recogniser, and those are a different argument.
    ///
    /// Numbers are deliberately *not* folded: "$25" and "twenty five dollars"
    /// score as different, because they are different things to have typed.
    /// That puts the burden on the reference, which must be written in the
    /// form that should end up on screen. Parakeet already does its own
    /// inverse text normalisation — it hears "twenty five thousand four
    /// hundred dollars" and writes "$25,400" — so a reference in spoken form
    /// scores a flawless transcript at 45% WER. Measured, on the first run of
    /// the bench set.
    public static func score(hypothesis: String, reference: String) -> Score {
        let hyp = words(hypothesis)
        let ref = words(reference)
        guard !ref.isEmpty else {
            return Score(substitutions: 0, deletions: 0, insertions: hyp.count,
                         referenceWords: 0)
        }
        // Silence against real speech: every reference word was missed. Also
        // the guard that keeps `1...hyp.count` below a valid range — and this
        // is not a hypothetical, it is what a failed transcription returns.
        guard !hyp.isEmpty else {
            return Score(substitutions: 0, deletions: ref.count, insertions: 0,
                         referenceWords: ref.count)
        }

        // Levenshtein with edit-type counts carried along. Two rows rather
        // than the full matrix: a meeting transcript is tens of thousands of
        // words and the full table would be gigabytes.
        struct Cell { var s = 0, d = 0, i = 0; var total: Int { s + d + i } }
        var prev = (0...hyp.count).map { n in Cell(s: 0, d: 0, i: n) }
        var curr = prev

        for r in 1...ref.count {
            curr[0] = Cell(s: 0, d: r, i: 0)
            for h in 1...hyp.count {
                if ref[r - 1] == hyp[h - 1] {
                    curr[h] = prev[h - 1]
                    continue
                }
                // Substitute, delete (a reference word the engine missed),
                // insert (a word the engine invented) — cheapest wins, and
                // ties go to substitution, which is what a human reading the
                // diff would call it.
                var sub = prev[h - 1]; sub.s += 1
                var del = prev[h];     del.d += 1
                var ins = curr[h - 1]; ins.i += 1
                var best = sub
                if del.total < best.total { best = del }
                if ins.total < best.total { best = ins }
                curr[h] = best
            }
            swap(&prev, &curr)
        }

        let final = prev[hyp.count]
        return Score(substitutions: final.s, deletions: final.d, insertions: final.i,
                     referenceWords: ref.count)
    }

    /// Case-folded, punctuation-stripped words. Apostrophes and inner hyphens
    /// are kept — "dont" is a different word from "don't", and pretending
    /// otherwise would hide a real error.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                String(token.unicodeScalars.filter {
                    CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "-" || $0 == "’"
                })
                .replacingOccurrences(of: "’", with: "'")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
            }
            .filter { !$0.isEmpty }
    }
}
