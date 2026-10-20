import Foundation

/// Turns whatever text is on screen right now into a short list of words
/// worth spelling correctly for *this* utterance. Pure, tested, and the
/// counterpart of `ContactTerms`: that one filters an address book into a
/// file, this one filters a window into something that never touches disk.
///
/// The distinction matters more than it looks. `Vocabulary` is a standing
/// claim — "whenever you hear this, write that" — and a wrong entry in it is
/// wrong forever, in every app, for every sentence. What comes out of here is
/// a claim about one dictation: these words are visibly in front of the
/// speaker as they talk, so if the transcript contains something that is
/// plainly one of them, that is probably what they said. Get it wrong and the
/// cost is one bad word in one utterance, and then it is gone.
///
/// That is the whole reason this is allowed to be looser than the vocabulary
/// files, and the reason it must never be written to one.
///
/// **What is kept.** A token has to be distinctive to survive: an everyday
/// word is dropped no matter how it is shaped (`CommonWords`), and what is
/// left must look like a name, an identifier or an acronym rather than
/// prose. Ordering is by weighted frequency — a term that appears three
/// times, or appears in the text nearest the cursor, beats one seen once in
/// a sidebar — so when the cap bites it is the incidental words that go.
public enum ContextTerms {

    /// How many terms a single dictation may carry. Small on purpose: these
    /// ride along in the polish prompt on the latency path, and a list long
    /// enough to contain the right answer by accident is a list long enough
    /// to contain a dozen wrong ones.
    public static let cap = 48

    /// Matches `VocabularyBoost.minTermLength`. Shorter than this and a term
    /// collides with ordinary speech more often than it rescues anything.
    public static let minLength = 4
    /// Beyond this it is not a word, it is a URL, a hash or a stack frame.
    /// Long enough for the longest thing anybody dictates and short enough to
    /// exclude a UUID, which is 36 and is on every developer's screen.
    public static let maxLength = 28

    /// Weight given to the first source. The caller passes text in order of
    /// relevance — what is under the cursor first, the rest of the window
    /// after — and a name in the sentence being written is worth more than
    /// the same name in a tab title.
    static let nearWeight = 3

    /// The terms worth carrying, most relevant first.
    ///
    /// - Parameters:
    ///   - sources: text to mine, most relevant first. The first element is
    ///     weighted; everything after it counts once.
    ///   - cap: most terms to return.
    ///   - common: the everyday-word guard. `.system` in the app; the
    ///     default keeps tests off the system dictionary.
    public static func extract(_ sources: [String], cap: Int = ContextTerms.cap,
                               common: CommonWords = .basic) -> [String] {
        var score: [String: Int] = [:]
        var casing: [String: String] = [:]
        var order: [String: Int] = [:]
        var seen = 0

        for (index, text) in sources.enumerated() {
            let weight = index == 0 ? nearWeight : 1
            for raw in tokens(in: text) {
                guard keeps(raw, common: common) else { continue }
                // The possessive is grammar, not spelling: "Cloudflare's" and
                // "Cloudflare" are one term, and the shorter one is the term.
                let token = stem(raw)
                let key = token.lowercased()
                if casing[key] == nil {
                    casing[key] = token
                    order[key] = seen
                    seen += 1
                }
                score[key, default: 0] += weight
            }
        }

        return score.keys
            .sorted {
                let (a, b) = (score[$0] ?? 0, score[$1] ?? 0)
                return a == b ? (order[$0] ?? 0) < (order[$1] ?? 0) : a > b
            }
            .prefix(cap)
            .compactMap { casing[$0] }
    }

    /// Characters that hold a token together. Letters and digits obviously;
    /// the rest are what identifiers are made of, so `snake_case`,
    /// `kebab-case`, `Module.Type` and `C++` survive as one token each.
    private static let joiners: Set<Character> = ["_", "-", ".", "+", "#", "'"]

    /// Split on whitespace, then shave punctuation off each end. Splitting on
    /// punctuation instead would cut `Module.Type` in half, and keeping the
    /// ends would leave `Siobhan,` and `(WhisperKit)` as their own words.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var token = Substring(raw)
            while let c = token.first, !c.isLetter, !c.isNumber { token = token.dropFirst() }
            while let c = token.last, !c.isLetter, !c.isNumber { token = token.dropLast() }
            return token.isEmpty ? nil : String(token)
        }
    }

    /// The word without a trailing possessive or contraction: "Hermes's" →
    /// "Hermes", "That's" → "That", "can't" → "can". The ending is grammar the
    /// speaker produces on their own; what wants spelling right is the word.
    ///
    /// Without this every apostrophe in a window arrives as its own "term",
    /// and because no dictionary lists contractions they all sail past the
    /// everyday-word guard looking like proper nouns.
    static func stem(_ token: String) -> String {
        guard let mark = token.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) else { return token }
        let head = String(token[..<mark])
        return head.isEmpty ? token : head
    }

    /// Whether a token is a hex run: a hash, a UUID, a commit, an id.
    /// Length is part of it — "beef", "face" and "added" are words, and it
    /// takes a long one before hex is the likelier explanation.
    static func isHexBlob(_ token: String) -> Bool {
        // Every joiner, not just the hyphen: a git range is "05dc526..915e9e1"
        // and its halves are each a character short of the threshold.
        let bare = token.filter { !joiners.contains($0) }
        guard bare.count >= 8 else { return false }
        return bare.allSatisfy { $0.isHexDigit }
    }

    /// Whether a word, or an obvious inflection of it, is everyday.
    ///
    /// `/usr/share/dict/words` lists lemmas: "tool" but not "tools", "exist"
    /// but not "existed", "minute" but not "minutes". Checking a token against
    /// it directly therefore waves through every plural, past tense and adverb
    /// in the window as though it were rare jargon — which is precisely what
    /// the first run of this code did, offering "tools", "tests", "minutes"
    /// and "existed" as names worth boosting.
    ///
    /// So the stem is tried too. Over-filtering is the safe direction here: a
    /// name lost from one utterance costs a capital letter, while an everyday
    /// word treated as a term is how ordinary speech gets rewritten.
    static func isCommon(_ word: String, common: CommonWords) -> Bool {
        let w = word.lowercased()
        if common.contains(w) { return true }
        for candidate in inflections(of: w) where common.contains(candidate) { return true }
        return false
    }

    /// Plausible lemmas for an inflected form. Crude on purpose — a real
    /// stemmer would be a dependency and a paragraph of tuning for a guess
    /// that is thrown away at the end of the sentence.
    static func inflections(of w: String) -> [String] {
        var out: [String] = []
        func drop(_ n: Int, add: String = "") {
            guard w.count > n + 1 else { return }
            out.append(String(w.dropLast(n)) + add)
        }
        if w.hasSuffix("ies") { drop(3, add: "y") }
        if w.hasSuffix("es") { drop(2); drop(1) }
        if w.hasSuffix("s") { drop(1) }
        if w.hasSuffix("ed") { drop(2); drop(2, add: "e"); drop(1) }
        if w.hasSuffix("ing") { drop(3); drop(3, add: "e") }
        if w.hasSuffix("ly") { drop(2) }
        if w.hasSuffix("est") { drop(3); drop(2) }
        if w.hasSuffix("er") { drop(2); drop(1) }
        // "running" → "runn" → "run": a doubled final consonant before the
        // ending. Done last so it only ever adds candidates.
        for candidate in out where candidate.count > 2 {
            let chars = Array(candidate)
            if chars[chars.count - 1] == chars[chars.count - 2] {
                out.append(String(candidate.dropLast()))
            }
        }
        return out
    }

    /// Whether a token is distinctive enough to be worth boosting.
    static func keeps(_ token: String, common: CommonWords) -> Bool {
        guard token.count >= minLength, token.count <= maxLength else { return false }
        guard token.contains(where: \.isLetter) else { return false }
        // Anything not a word or an identifier. An address, a URL or a path
        // is never what somebody is dictating, and each one drags a handful
        // of junk tokens in behind it.
        guard !token.contains("@"), !token.contains("://"), !token.contains("/") else { return false }
        guard token.allSatisfy({ $0.isLetter || $0.isNumber || joiners.contains($0) }) else { return false }
        // A hash, a commit, a session id. These are shaped exactly like
        // identifiers — hex runs joined by hyphens — so the identifier rule
        // below waves them through, and a developer's screen is covered in
        // them. Nobody has ever dictated one.
        if isHexBlob(token) { return false }

        // The everyday-word guard, before any of the shape rules: a common
        // word is common however it is capitalised, and this is the check
        // whose absence let `Sonnet`, `dictation` and `transcript` into a
        // vocabulary file and start rewriting ordinary speech.
        let word = stem(token)
        let letters = String(word.filter(\.isLetter))
        if isCommon(letters, common: common) { return false }
        guard letters.count >= 2 else { return false }

        let hasLower = word.contains(where: \.isLowercase)
        let hasUpper = word.contains(where: \.isUppercase)
        let hasDigit = word.contains(where: \.isNumber)
        let inner = word.dropFirst()

        // An identifier, and this has to be tested *first*. It is the only
        // rule that can reject, and a joined token trips the internal-capital
        // rule on the way past: `inspect.Parameter` would come back a term on
        // the strength of its capital P, when it is two ordinary words with a
        // dot between them. A window full of code is a window full of those.
        if word.contains(where: { joiners.contains($0) }) {
            let parts = word.split(whereSeparator: { joiners.contains($0) })
            return parts.contains { !isCommon(String($0), common: common) }
        }
        // An internal capital: WhisperKit, SwiftPM, McCarthy, iOS.
        if hasLower && inner.contains(where: \.isUppercase) { return true }
        // An acronym, and short enough still to be one: CTC, HIPAA, GDPR.
        if hasUpper && !hasLower && word.count <= 10 { return true }
        // Letters and digits together: gpt5, s3, sha256, m4.
        if hasDigit && !letters.isEmpty { return true }
        // A proper noun. Everyday words are already gone, so what is left
        // starting with a capital is a name — which is the whole point.
        if word.first?.isUppercase == true { return true }
        // Lowercase jargon no dictionary has heard of: kubectl, npm, webhooks.
        // Held to a longer minimum because this is the loosest rule here and a
        // typo four letters long looks exactly like it.
        if letters.count >= 5 { return true }

        return false
    }
}
