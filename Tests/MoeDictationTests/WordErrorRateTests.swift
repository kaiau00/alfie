import Testing
@testable import MoeDictation

@Suite("WordErrorRate")
struct WordErrorRateTests {

    @Test("a perfect transcript scores zero")
    func perfect() {
        let s = WordErrorRate.score(hypothesis: "send it on Friday",
                                    reference: "send it on Friday")
        #expect(s.errors == 0)
        #expect(s.rate == 0)
        #expect(s.referenceWords == 4)
    }

    /// The reason both sides are normalised: otherwise this measures the
    /// punctuation rules rather than the recogniser.
    @Test("case and punctuation are not errors")
    func normalisation() {
        let s = WordErrorRate.score(hypothesis: "Send it on Friday.",
                                    reference: "send it on friday")
        #expect(s.errors == 0)
    }

    @Test("each edit is counted as its own kind")
    func editKinds() {
        // reference: the quick brown fox
        // hypothesis: the quick red fox jumps   → 1 substitution, 1 insertion
        let s = WordErrorRate.score(hypothesis: "the quick red fox jumps",
                                    reference: "the quick brown fox")
        #expect(s.substitutions == 1)
        #expect(s.insertions == 1)
        #expect(s.deletions == 0)
        #expect(s.rate == 0.5)
    }

    @Test("a dropped word is a deletion")
    func deletion() {
        let s = WordErrorRate.score(hypothesis: "the brown fox",
                                    reference: "the quick brown fox")
        #expect(s.deletions == 1)
        #expect(s.substitutions == 0)
        #expect(s.insertions == 0)
    }

    /// Whisper's classic failure. A rate above 1 is meaningful and must not
    /// be clamped away — but `accuracy` should still floor at zero.
    @Test("a hallucinated repeat scores over 100%")
    func runaway() {
        let s = WordErrorRate.score(hypothesis: String(repeating: "thanks ", count: 20),
                                    reference: "thanks")
        #expect(s.rate > 1)
        #expect(s.accuracy == 0)
    }

    @Test("an empty reference is not a division by zero")
    func emptyReference() {
        #expect(WordErrorRate.score(hypothesis: "", reference: "").rate == 0)
        #expect(WordErrorRate.score(hypothesis: "something", reference: "").rate == 1)
    }

    @Test("silence against real speech is all deletions")
    func emptyHypothesis() {
        let s = WordErrorRate.score(hypothesis: "", reference: "the quick brown fox")
        #expect(s.deletions == 4)
        #expect(s.rate == 1)
    }

    /// "dont" and "don't" are different words and the difference is exactly
    /// the kind of thing the polish pass is meant to fix, so it must show.
    @Test("apostrophes are kept, other punctuation is not")
    func apostrophes() {
        #expect(WordErrorRate.words("Don't — really!") == ["don't", "really"])
        #expect(WordErrorRate.score(hypothesis: "dont", reference: "don't").errors == 1)
        // A curly apostrophe is the same word as a straight one.
        #expect(WordErrorRate.score(hypothesis: "don’t", reference: "don't").errors == 0)
    }

    /// Deliberately *not* normalised: "$25" and "twenty five dollars" are
    /// different things to have typed. The consequence is that references
    /// must be written in the form that should end up on screen — Parakeet
    /// normalises numbers itself, so a spoken-form reference scores a correct
    /// transcript as badly wrong.
    @Test("written numbers are not folded into spoken ones")
    func numbersStayDifferent() {
        let s = WordErrorRate.score(hypothesis: "twenty five dollars", reference: "$25")
        #expect(s.errors > 0)
    }
}

@Suite("WordErrorRate.total")
struct WordErrorRateTotalTests {

    /// Pooled, not averaged. The two differ whenever clips are different
    /// lengths, and averaging lets a short clean clip cancel a long bad one —
    /// which is exactly how a set gets flattered.
    @Test("errors and words are pooled before dividing")
    func pooledNotAveraged() {
        // 0 errors of 90 words, then 10 errors of 10 words.
        let clean = WordErrorRate.Score(substitutions: 0, deletions: 0, insertions: 0,
                                        referenceWords: 90)
        let bad = WordErrorRate.Score(substitutions: 10, deletions: 0, insertions: 0,
                                      referenceWords: 10)
        let total = WordErrorRate.total([clean, bad])
        #expect(total.referenceWords == 100)
        #expect(total.errors == 10)
        #expect(total.rate == 0.1)          // pooled
        // The mean of the rates would be 0.5 — five times worse, and wrong.
        #expect(total.rate != (clean.rate + bad.rate) / 2)
    }

    @Test("edit kinds survive the sum")
    func kindsSummed() {
        let a = WordErrorRate.Score(substitutions: 1, deletions: 2, insertions: 3,
                                    referenceWords: 10)
        let b = WordErrorRate.Score(substitutions: 4, deletions: 5, insertions: 6,
                                    referenceWords: 20)
        let total = WordErrorRate.total([a, b])
        #expect(total.substitutions == 5)
        #expect(total.deletions == 7)
        #expect(total.insertions == 9)
        #expect(total.referenceWords == 30)
    }

    @Test("no clips is not a division by zero")
    func empty() {
        let total = WordErrorRate.total([])
        #expect(total.referenceWords == 0)
        #expect(total.rate == 0)
    }
}
