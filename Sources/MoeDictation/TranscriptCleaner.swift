import Foundation

/// Rule-based cleanup of a raw dictation transcript.
///
/// Parakeet already produces decent casing, numbers and most punctuation; what
/// it leaves behind is fillers, stutters, spoken punctuation ("comma", "new
/// line") and the odd lowercase sentence start. Plain rules fix most of that
/// without a model round-trip, which is what keeps dictation feeling instant.
/// Everything here is pure Foundation so it can be unit-tested and reused by
/// the gateway's voice-note path.
///
/// Stages run in a fixed order (see `clean(_:rules:vocabulary:)`) because each
/// one relies on the previous having tidied the text: filler removal exposes
/// stutters, spoken punctuation creates the sentence boundaries that
/// capitalisation keys off, and so on.
///
/// Known failure cases, kept deliberately rather than solved with a model:
///
/// - Spoken punctuation is only left alone when preceded by a determiner,
///   possessive or a known compound head ("the period of time", "a comma",
///   "her period", "trial period") or followed by a digit ("period 30"). "She has colon cancer" or "period pain" will
///   still be converted — the literal reading only wins when the word is
///   spoken with an article.
/// - "you know" / "I mean" are only removed when Parakeet already fenced
///   them with commas ("so, you know, it works", "I mean, it's fine").
///   Without the commas they are kept — losing "I mean it" would be worse
///   than keeping a filler.
/// - "like" is never touched. Too often a verb or a preposition.
/// - Spoken addresses ("john at example dot com") *are* converted now, but
///   only where the shape is unmistakable — `SpokenAddress` explains the
///   anchor and what it deliberately leaves alone.
/// - Stutter collapse only handles short (≤ 3 letter) exact duplicates and
///   skips "had had" / "that that"; deliberate repeats like "no no" or
///   "bye bye" are collapsed.
/// - The pronoun rule uppercases every standalone `i`, including a variable
///   named `i` in dictated code.
/// - Sentence capitalisation fires after any `.` followed by a space, so
///   "e.g. something" becomes "e.g. Something".
public enum TranscriptCleaner {

    /// Which stages run. Callers inserting into a search field want the text
    /// left bare; the defaults suit prose typed at a cursor.
    public struct Rules: Sendable {
        public var removeFillers = true
        public var spokenPunctuation = true
        public var collapseStutters = true
        public var capitalise = true
        /// Append a full stop when a multi-word utterance ends on a letter or
        /// digit. A single word or short phrase (a search term, a filename)
        /// stays a bare token.
        public var terminalPunctuation = true
        /// Leave one space at the end so the next dictation, or the user's
        /// own typing, doesn't run straight into the last word.
        public var trailingSpace = true

        public init() {}

        public static let `default` = Rules()
    }

    /// The app-facing entry point: default rules, the shared vocabulary.
    public static func clean(_ text: String) -> String {
        clean(text, rules: .default, vocabulary: .shared)
    }

    public static func clean(_ text: String, vocabulary: Vocabulary) -> String {
        clean(text, rules: .default, vocabulary: vocabulary)
    }

    /// Tests use this with an explicit (or no) vocabulary so they never touch
    /// the user's file.
    public static func clean(_ text: String, rules: Rules, vocabulary: Vocabulary? = nil) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        var s = normaliseWhitespace(text)

        // 1. Vocabulary first: the rest of the pipeline should see the
        //    canonical spelling, and a replacement never introduces fillers
        //    or spoken punctuation, so nothing later is undone.
        if let vocabulary { s = vocabulary.apply(to: s) }

        // 2. Addresses before anything that removes or moves a word: an
        //    email address is read off the run of words as spoken, and a
        //    filler stripped out of the middle of one would break the shape
        //    that identifies it. Returns the text untouched unless it finds
        //    "dot" next to a real top-level domain — see `SpokenAddress`.
        s = SpokenAddress.rewrite(s)

        // 3. Fillers before stutters: "the um the" only becomes "the the"
        //    once the "um" is gone.
        if rules.removeFillers { s = removeFillers(s) }

        // 4. Stutters before spoken punctuation, so "period period" (a real
        //    stutter) collapses before it would become "..".
        if rules.collapseStutters { s = collapseStutters(s) }

        // 5. Spoken punctuation makes the sentence boundaries that
        //    capitalisation keys off, so it runs before that stage.
        if rules.spokenPunctuation { s = convertSpokenPunctuation(s) }

        // 6. Tidy blanks-before-punctuation and doubled commas left by the
        //    stages above, before capitalisation looks for ". x".
        s = tidyPunctuation(s)

        if rules.capitalise { s = capitalise(s) }

        if rules.terminalPunctuation { s = addTerminalPunctuation(s) }

        s = s.trimmingCharacters(in: .whitespaces)
        if rules.trailingSpace, !s.isEmpty, !s.hasSuffix("\n") { s += " " }
        return s
    }

    // MARK: - Stages

    /// Collapse runs of blanks, trim, and strip blanks around newlines so a
    /// "new line" never leaves a dangling space. A leading or trailing
    /// newline is kept: the ASR never produces one, so it was dictated on
    /// purpose ("new line" first thing means "break here, then type").
    static func normaliseWhitespace(_ s: String) -> String {
        var t = replace(s, #"[ \t\r\x{00A0}]+"#, with: " ")
        t = replace(t, #" ?\n ?"#, with: "\n")
        t = replace(t, #"^ +| +$"#, with: "")
        return t
    }

    /// Filler words plus any comma glued to them. Lookarounds instead of `\b`
    /// so "uh-huh" and contractions survive intact.
    private static let fillerPattern =
        #"(?<![\w'’-])(?:um+|uh+|er+|erm|ah+|hmm+|hm+|mmm+)(?![\w'’-]),?\s*"#

    /// Two-word fillers go only when the ASR already fenced them with commas —
    /// the one reliable sign the speaker meant them as filler rather than
    /// "you know him" or "I mean it".
    private static let phraseFillerPattern =
        #"(?<=^|[,;])\s*(?:you know|i mean),\s*"#

    static func removeFillers(_ s: String) -> String {
        var t = replace(s, fillerPattern, with: "")
        t = replace(t, phraseFillerPattern, with: " ")
        return normaliseWhitespace(t)
    }

    /// Legitimate doubles the short-word rule would otherwise eat.
    private static let stutterExceptions: Set<String> = ["had", "that"]

    /// A run of two or more adjacent exact duplicates of a word up to three
    /// letters ("the the the" is one match, so it collapses in a single
    /// pass). Longer words are skipped: "very very" is usually intentional
    /// emphasis. Digits are skipped too ("10 10").
    private static let stutterRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z]{1,3})\b(?: \1\b)+"#, options: [.caseInsensitive])

    static func collapseStutters(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in stutterRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            if stutterExceptions.contains(word.lowercased()) { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += word
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Spoken token → what to emit.
    private static let spoken: [String: String] = [
        "full stop": ".",
        "period": ".",
        "comma": ",",
        "question mark": "?",
        "exclamation mark": "!",
        "exclamation point": "!",
        "new paragraph": "\n\n",
        "new line": "\n",
        "open quote": "\"",
        "close quote": "\"",
        "semicolon": ";",
        "semi colon": ";",
        "colon": ":",
        "dash": " \u{2014} ",
    ]

    /// If the token follows one of these it is being *talked about*, not
    /// dictated ("the period", "a comma", "each dash").
    /// "no" and "one" are deliberately absent: "no dash go" and "one new
    /// line two" are far more common in dictation than "no comma there".
    private static let literalPrecedents: Set<String> = [
        "the", "a", "an", "this", "that", "each", "every", "another",
        "of", "my", "your", "his", "her", "its", "our", "their", "any",
        "some", "same", "first", "last", "next", "second",
        // Compounds whose second half is a spoken token: "trial period",
        // "grace period", "oxford comma", "notice period".
        "trial", "grace", "probation", "notice", "waiting", "time", "oxford",
    ]

    private static let spokenRegex: NSRegularExpression = {
        // Longest first so "exclamation mark" beats nothing shorter and
        // "semi colon" beats "colon".
        let alts = spoken.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // The trailing [.,]? swallows punctuation Parakeet sometimes appends
        // to the spoken word itself ("period." → ".").
        return try! NSRegularExpression(
            pattern: #"(?<![\w'-])("# + alts + #")(?![\w'-])[.,]?"#,
            options: [.caseInsensitive])
    }()

    /// Convert when the token ends the utterance or is followed by a word,
    /// and is not preceded by a determiner. See the type doc for what that
    /// heuristic gets wrong.
    static func convertSpokenPunctuation(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in spokenRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range(at: 1)).lowercased()
            var afterLoc = m.range.location + m.range.length
            // Only the previous word and the next non-blank character are
            // consulted, so look at bounded windows rather than copying the
            // whole prefix and suffix per match (quadratic on long input).
            let before = window(ns, before: m.range.location, max: 48)
            let after = window(ns, from: afterLoc, max: 8)
            guard let symbol = spoken[token],
                  shouldConvert(before: before, after: after) else { continue }

            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out = out.trimmingTrailingBlanks()
            switch token {
            case "open quote":
                // Space before, glued to the next word.
                if let l = out.last, l != "\n" { out += " " }
                out += symbol
                afterLoc = skipBlanks(ns, from: afterLoc)
            case "new line", "new paragraph", "dash":
                out += symbol
                afterLoc = skipBlanks(ns, from: afterLoc)
            default:
                // Close quote and the sentence marks glue to the previous
                // word; the original space after them is kept. When the ASR
                // already closed the sentence ("Done. Period.") don't double
                // up.
                if symbol == "\"" || out.last != symbol.first { out += symbol }
            }
            cursor = afterLoc
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func shouldConvert(before: String, after: String) -> Bool {
        let prev = before.split(whereSeparator: { $0 == " " || $0 == "\n" }).last
            .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() }
        if let prev, literalPrecedents.contains(prev) { return false }
        let rest = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return true }
        return rest.first.map { $0.isLetter || $0 == "\"" } ?? false
    }

    /// Up to `max` UTF-16 units ending at `loc`, aligned so a surrogate pair
    /// is never split.
    private static func window(_ ns: NSString, before loc: Int, max: Int) -> String {
        var start = Swift.max(0, loc - max)
        if start < ns.length { start = ns.rangeOfComposedCharacterSequence(at: start).location }
        return ns.substring(with: NSRange(location: start, length: loc - start))
    }

    private static func window(_ ns: NSString, from loc: Int, max: Int) -> String {
        var end = Swift.min(ns.length, loc + max)
        if end < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: end)
            if r.location < end { end = r.location }
        }
        return ns.substring(with: NSRange(location: loc, length: end - loc))
    }

    private static func skipBlanks(_ ns: NSString, from: Int) -> Int {
        var i = from
        while i < ns.length, ns.character(at: i) == 0x20 { i += 1 }
        return i
    }

    /// Fix what the earlier stages leave behind: blanks before punctuation,
    /// doubled commas from filler removal, a leading comma.
    static func tidyPunctuation(_ s: String) -> String {
        var t = replace(s, #" +([,.;:?!])"#, with: "$1")
        t = replace(t, #"([,;:]) *(?=[,;:.?!])"#, with: "")
        t = replace(t, #"^[,;:] *"#, with: "")
        t = replace(t, #"\n[,;:] *"#, with: "\n")
        return normaliseWhitespace(t)
    }

    /// First letter of the text, of each sentence after `. ? !`, and of
    /// each line; plus the pronoun "I" and its contractions. A quoted
    /// fragment is left as spoken. Nothing is ever lowercased — Parakeet's
    /// casing of names and acronyms is better than any rule here.
    private static let sentenceStartRegex = try! NSRegularExpression(pattern: #"(^|[.?!] +|\n)([a-z])"#)

    /// Standalone `i`, or `i` + a contraction suffix with either apostrophe.
    /// A following `.` counts only when it ends the word ("i." not "i.e.").
    private static let pronounRegex = try! NSRegularExpression(
        pattern: #"(?<![\w'’])i(?=$|[ \n,?!;:]|\.(?!\w)|['’](?:m|ve|ll|d)\b)"#)

    static func capitalise(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        for m in sentenceStartRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = m.range(at: 2)
            ns.replaceCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return pronounRegex.stringByReplacingMatches(
            in: ns as String, range: NSRange(location: 0, length: ns.length), withTemplate: "I")
    }

    /// A single word or short phrase stays bare; anything sentence-length
    /// gets its full stop.
    static func addTerminalPunctuation(_ s: String) -> String {
        guard let last = s.last, last.isLetter || last.isNumber else { return s }
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" })
        return words.count > 3 ? s + "." : s
    }

    // MARK: - Helpers

    /// Compiled once per pattern; NSRegularExpression is immutable and safe
    /// to share across threads, so a lock around the table is enough.
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    /// Case-insensitive regex replace. The patterns here are all constants,
    /// so a bad one is a programming error, hence `try!`.
    static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        regexCacheLock.lock()
        let cached = regexCache[pattern]
        regexCacheLock.unlock()
        let rx: NSRegularExpression
        if let cached {
            rx = cached
        } else {
            rx = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            regexCacheLock.lock()
            regexCache[pattern] = rx
            regexCacheLock.unlock()
        }
        return rx.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

private extension String {
    func trimmingTrailingBlanks() -> String {
        var t = self
        while t.last == " " { t.removeLast() }
        return t
    }
}
