import Testing
@testable import MoeMeeting

@Suite("TokenRewrite")
struct TokenRewriteTests {

    /// The stream as Parakeet emits it: a leading ▁ starts a word, bare
    /// tokens continue it.
    private func stream(_ pieces: [(String, Double, Double)]) -> [TimedToken] {
        pieces.map { TimedToken($0.0, $0.1, $0.2) }
    }

    private func text(_ tokens: [TimedToken]) -> String {
        tokens.map { $0.token.hasPrefix("▁") ? " " + $0.token.dropFirst() : $0.token }
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    @Test("a multi-token word is replaced on its first token")
    func multiTokenWord() {
        let tokens = stream([("▁Live", 0.0, 0.3), ("Mar", 0.3, 0.5), ("ley", 0.5, 0.7),
                             ("▁said", 0.7, 0.9)])
        let out = TokenRewrite.apply([(from: "LiveMarley", to: "Livmarli")], to: tokens)
        #expect(text(out) == "Livmarli said")
    }

    /// The whole reason corrections are applied to tokens rather than text:
    /// the times drive speaker attribution and the timeline.
    @Test("every timestamp survives untouched")
    func timingsPreserved() {
        let tokens = stream([("▁Live", 0.0, 0.3), ("Mar", 0.3, 0.5), ("ley", 0.5, 0.7)])
        let out = TokenRewrite.apply([(from: "LiveMarley", to: "Livmarli")], to: tokens)
        #expect(out.count == tokens.count)
        for (a, b) in zip(out, tokens) {
            #expect(a.start == b.start)
            #expect(a.end == b.end)
        }
    }

    @Test("a single-token word is replaced in place")
    func singleToken() {
        let tokens = stream([("▁Ask", 0.0, 0.2), ("▁Shevonne", 0.2, 0.6), ("▁about", 0.6, 0.8)])
        let out = TokenRewrite.apply([(from: "Shevonne", to: "Siobhan")], to: tokens)
        #expect(text(out) == "Ask Siobhan about")
    }

    @Test("punctuation after the word is kept")
    func trailingPunctuation() {
        let tokens = stream([("▁An", 0.0, 0.2), ("win", 0.2, 0.4), (",", 0.4, 0.4),
                             ("▁yes", 0.4, 0.6)])
        let out = TokenRewrite.apply([(from: "Anwin", to: "Anwen")], to: tokens)
        #expect(text(out) == "Anwen, yes")
    }

    @Test("matching ignores case and punctuation")
    func foldedMatching() {
        let tokens = stream([("▁anwin", 0.0, 0.4), ("▁left", 0.4, 0.6)])
        let out = TokenRewrite.apply([(from: "Anwin,", to: "Anwen")], to: tokens)
        #expect(text(out) == "Anwen left")
    }

    /// The rescorer reports a replacement per position it found. Firing one
    /// everywhere would rewrite occurrences it deliberately left alone.
    @Test("a correction fires once, not on every occurrence")
    func firesOnce() {
        let tokens = stream([("▁Anwin", 0.0, 0.3), ("▁and", 0.3, 0.5), ("▁Anwin", 0.5, 0.8)])
        let out = TokenRewrite.apply([(from: "Anwin", to: "Anwen")], to: tokens)
        #expect(text(out) == "Anwen and Anwin")
    }

    @Test("a word that is not a correction is left alone")
    func untouched() {
        let tokens = stream([("▁the", 0.0, 0.2), ("▁meeting", 0.2, 0.6)])
        let out = TokenRewrite.apply([(from: "Anwin", to: "Anwen")], to: tokens)
        #expect(text(out) == "the meeting")
    }

    @Test("no corrections, no changes")
    func noReplacements() {
        let tokens = stream([("▁hello", 0.0, 0.4)])
        #expect(TokenRewrite.apply([], to: tokens) == tokens)
        #expect(TokenRewrite.apply([(from: "a", to: "b")], to: []) == [])
    }

    /// A partial word must never match: replacing "Mar" inside "LiveMarley"
    /// would corrupt the transcript rather than fix it.
    @Test("only whole words match")
    func wholeWordsOnly() {
        let tokens = stream([("▁Live", 0.0, 0.3), ("Mar", 0.3, 0.5), ("ley", 0.5, 0.7)])
        let out = TokenRewrite.apply([(from: "Mar", to: "March")], to: tokens)
        #expect(text(out) == "LiveMarley")
    }

    @Test("an empty replacement is ignored rather than deleting the word")
    func emptyReplacement() {
        let tokens = stream([("▁Anwin", 0.0, 0.4)])
        let out = TokenRewrite.apply([(from: "Anwin", to: "")], to: tokens)
        #expect(text(out) == "Anwin")
    }

    /// Segments are built by concatenating tokens, so an emptied token has to
    /// contribute nothing — not a stray space.
    @Test("emptied tokens leave no gap in the text")
    func emptiedTokensAreInvisible() {
        let tokens = stream([("▁Live", 0.0, 0.3), ("Mar", 0.3, 0.5), ("ley", 0.5, 0.7),
                             ("▁is", 0.7, 0.8), ("▁here", 0.8, 1.0)])
        let out = TokenRewrite.apply([(from: "LiveMarley", to: "Livmarli")], to: tokens)
        #expect(text(out) == "Livmarli is here")
        #expect(!text(out).contains("  "))
    }

    @Test("several corrections apply in one pass")
    func multipleCorrections() {
        let tokens = stream([("▁An", 0.0, 0.2), ("win", 0.2, 0.4), ("▁met", 0.4, 0.6),
                             ("▁Shevonne", 0.6, 1.0)])
        let out = TokenRewrite.apply([(from: "Anwin", to: "Anwen"),
                                      (from: "Shevonne", to: "Siobhan")], to: tokens)
        #expect(text(out) == "Anwen met Siobhan")
    }
}

/// The suite above uses U+2581 word marks. FluidAudio actually delivers a
/// plain leading space, and assuming otherwise is what made the first version
/// of TokenRewrite silently do nothing — so the real format gets its own
/// coverage, taken verbatim from a logged meeting window.
@Suite("TokenRewrite, space-marked stream (what FluidAudio really sends)")
struct TokenRewriteSpaceMarkedTests {

    private func stream(_ pieces: [String]) -> [TimedToken] {
        pieces.enumerated().map { TimedToken($0.element, Double($0.offset) * 0.1,
                                             Double($0.offset) * 0.1 + 0.1) }
    }

    private func text(_ tokens: [TimedToken]) -> String {
        tokens.map(\.token).joined().trimmingCharacters(in: .whitespaces)
    }

    /// The exact token stream logged from a meeting window, which the first
    /// implementation read as one 60-character word and left untouched.
    private var real: [TimedToken] {
        stream([" Ne", "eds", " mig", "r", "ation", " is", " blo", "ck", "ed", " on",
                " C", "lo", "ud", "fl", "are", " or", " on", " the", " P", "ost",
                "G", "uz", " up", "gra", "de", "."])
    }

    @Test("a space-marked multi-token word is found and replaced")
    func spaceMarked() {
        let out = TokenRewrite.apply([(from: "PostGuz", to: "Postgres")], to: real)
        #expect(text(out) == "Needs migration is blocked on Cloudflare or on the Postgres upgrade.")
    }

    @Test("the stream splits into real words, not one long run")
    func wordsAreSplit() {
        let words = TokenRewrite.words(in: real).map(\.text)
        #expect(words.count == 11)
        #expect(words.first == "Needs")
        #expect(words.contains("Cloudflare"))
        #expect(words.contains("PostGuz"))
        #expect(words.last == "upgrade")
    }

    @Test("timings survive on the real stream too")
    func timingsPreserved() {
        let out = TokenRewrite.apply([(from: "PostGuz", to: "Postgres")], to: real)
        #expect(out.count == real.count)
        for (a, b) in zip(out, real) {
            #expect(a.start == b.start)
            #expect(a.end == b.end)
        }
    }

    @Test("the leading space is kept, so words do not run together")
    func spacingKept() {
        let out = TokenRewrite.apply([(from: "Cloudflare", to: "Cloudflare")], to: real)
        #expect(!text(out).contains("theCloudflare"))
        #expect(text(out).contains(" Cloudflare "))
    }
}
