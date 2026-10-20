import Foundation

/// Moe's plumbing describing itself, and the one rule that keeps it off the
/// island.
///
/// Hermes tells Moe about its own machinery by sending Moe a message, the
/// same way it would tell a developer on Slack. The wording is Hermes's:
///
///     ⚠️ Cron 'moe-proactive' failed: claude exited unexpectedly (code 143)
///     ⚠️ Cron job 'moe-proactive' was interrupted — the gateway is restarting…
///     ⚠️ Agent session appears stalled (last activity 12 min ago). Try /new…
///     ⚠️ Session database corruption detected… Run `hermes doctor --fix`
///     [Background process 3de34721 finished with exit code 1~ …]
///
/// The first six of these reached a person, on the island, with the amber
/// pulse Moe uses for something worth interrupting them over. None named
/// anything they could do; most named a job they have never heard of.
///
/// `moe-screen`'s `deliver.py` drops these before an inbox file is written;
/// this is the same rule on the reading side, where the copies it cannot
/// reach pass through — a file written by an older plugin, by
/// `hermes send --to moe`, or before that fix was installed.
///
/// **The rule is the shape, never the reason.** The first version listed
/// reasons — exit 143, then the spend guard — and four other kinds walked
/// past it. Reasons are Hermes's and it keeps inventing them; the shapes
/// have been stable since the beginning.
///
/// **This file and `deliver.py` are two copies of one rule, and the first
/// time they were written they disagreed four ways** — Swift had no gateway
/// rule at all, Python did not know `❗` or loose spacing — while each test
/// suite proved only its own copy. Both are now tested against
/// `Tests/vectors/machinery-notices.json`. Change the rule in both, or in
/// neither.
public enum MachineryNotice {

    /// What Hermes puts on the front of a notice about itself.
    ///
    /// `⚠️` is U+26A0 followed by the variation selector U+FE0F, and Swift
    /// joins the two into one `Character` — so comparing against the bare
    /// `"⚠"` matches nothing Hermes actually sends. That is the same class of
    /// mistake as the pattern this replaced, one encoding layer down, and it
    /// is why every fixture is a real logged string rather than one typed
    /// from memory.
    private static let marks: Set<Character> =
        ["⚠️", "⚠", "♻️", "♻", "❗", "⏱️", "⏱", "✖", "🛑", "🔴", "\u{FE0F}", " ", "\t", "["]

    /// Shapes that name themselves, with or without a mark. Each was read
    /// out of the Hermes source — `cron/scheduler.py`, `gateway/run.py`,
    /// `gateway/session_stall.py`, `gateway/delivery_ledger.py`.
    private static let openings = [
        "agent session", "agent inactive for", "recovered reply",
        "session database corruption", "background process",
    ]

    /// True for anything Hermes sends about itself rather than about the
    /// person's life.
    ///
    /// Deliberately narrow in one way: it anchors at the start, so "the cron
    /// job Dan asked about failed, he says" is a person talking about a job
    /// and stays a message.
    public static func isJobFailure(_ text: String) -> Bool {
        let trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var bare = trimmed
        while let c = bare.first, marks.contains(c) { bare = bare.dropFirst() }
        let low = bare.lowercased()

        // `Cron 'name' …` and `Cron job 'name' …`. Everything after the
        // quoted name is machinery, whatever the verb: "was interrupted"
        // is one word from "failed" and fires on every gateway restart.
        for lead in ["cron job ", "cron "] where low.hasPrefix(lead) {
            let rest = bare.dropFirst(lead.count).drop { $0 == " " }
            if rest.first == "'", let close = rest.dropFirst().firstIndex(of: "'") {
                return !rest[rest.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        if openings.contains(where: low.hasPrefix) { return true }
        if leadsWithSomethingOnlyAMachineHas(trimmed) { return true }
        // "Gateway" on its own is a word people use, so that shape alone
        // needs one of Hermes's marks in front of it.
        return bare.count != trimmed.count && low.hasPrefix("gateway ")
    }

    /// The words a turn uses to say it has nothing to say.
    ///
    /// On 2026-09-30 10:45 a resumed conversation's silent warm-up turn
    /// reached the island as a Heads-up card whose whole text was `noop`.
    /// A reply that is empty, or that is ONLY one of these tokens, is the
    /// brain declining to speak — never a message for the person.
    static let silenceTokens: Set<String> = [
        "noop", "no-op", "no_op", "[silent]", "silent", "no_reply", "[no_reply]",
        "(no response)", "no response", "(silent)", "[noop]",
    ]

    /// True for a notice that says nothing: empty, whitespace, or a bare
    /// silence token (any case, in backticks or quotes, with a trailing full
    /// stop). Anchored to the WHOLE text, so "noop is what the log said" is
    /// still a sentence and still shown.
    public static func isSilence(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = CharacterSet(charactersIn: "`\"'\u{201C}\u{201D}*")
        t = t.trimmingCharacters(in: wrappers)
        if t.hasSuffix(".") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        return silenceTokens.contains(t.lowercased())
    }

    /// The four SHAPES of a line that is not Moe's words, and the name of the
    /// one that matched.
    ///
    /// The `openings` above are a list of sentences, and on 2026-09-14 six new
    /// sentences walked past them into the owner's own Telegram thread — a
    /// redirect notice with an iteration counter, a tip about `/busy queue`,
    /// two tool ids, and the memory plug-in announcing itself by directory
    /// name. He asked "why does it show this technical stuff?".
    ///
    /// So these are shapes, and each is a thing **a person does not have**:
    ///
    /// - `slash command` — an instruction to type `/stop` or `/busy queue`.
    ///   Someone messaging Moe from their phone has no command line.
    /// - `tool name` — a `snake_case` identifier announced with an ellipsis or
    ///   a colon (`gmail_status...`, `moe_profile...`). That is a name the
    ///   model calls, never a name a person knows.
    /// - `plug-in name` — one of our own `moe-*` plug-in directories. Open
    ///   ended, so it catches the plug-in nobody has written yet.
    /// - `loop counter` — a labelled fraction inside a bracket, `(iteration
    ///   3/60)` or `(step 2/9)`. They asked a question; they did not enrol in
    ///   a run.
    /// - `memory indicator` — `recalled 9 memories`, the template Hermes
    ///   builds every memory provider's status line from.
    ///
    /// Two of those five were widened after a review asked what would happen
    /// to `↪ Resumed run (step 2/9)` and to a memory provider not named
    /// `moe-*`. Both walked straight through, because the shapes knew the word
    /// "iteration" and the prefix "moe-" — a list of one word wearing the
    /// costume of a rule. What varies is the label; what does not is the
    /// bracket and the template.
    ///
    /// Narrow on purpose, so ordinary prose survives: the slash shape wants a
    /// lowercase word and refuses a second slash, which leaves `/Users/you`,
    /// `and/or` and `9/15` alone, and the counter wants its fraction bracketed,
    /// which leaves "page 4/10 of the contract" and "due 10/1" alone.
    ///
    /// **`deliver.py`'s `not_moes_words` is the other copy of this**, with the
    /// same four patterns; `Tests/vectors/machinery-notices.json` is what
    /// stops them drifting apart.
    static let shapes: [(name: String, pattern: String)] = [
        ("slash command",   #"(?:^|[\s`("'])/[a-z][a-z-]{1,15}\b(?!/)"#),
        ("tool name",       #"(?m)^\W{0,4}[a-z][a-z0-9]*(?:_[a-z0-9]+)+\s*(?:\.\.\.|…|:)"#),
        ("plug-in name",    #"\bmoe-[a-z][a-z0-9-]*\b"#),
        ("loop counter",    #"(?i)\([^)]*\b[a-z]+\s+\d{1,4}\s*/\s*\d{1,4}\b[^)]*\)"#),
        ("memory indicator", #"(?i)\brecalled\s+\d+\s+memor(?:y|ies)\b"#),
    ]

    /// The shape a text breaks, or nil when it reads as something Moe said.
    ///
    /// Returns the NAME rather than a bool so a failing test says which rule
    /// was broken and by what, instead of sending its reader to the patterns
    /// to work it out.
    public static func notMoesWords(_ text: String) -> String? {
        let scanned = withoutTrailerMarkup(text)
        if scanned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let whole = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)
        for shape in shapes {
            guard let re = try? NSRegularExpression(pattern: shape.pattern) else { continue }
            if re.firstMatch(in: scanned, range: whole) != nil { return shape.name }
        }
        return nil
    }

    /// `[[moe-open: dan-call | … ]]` and its kin taken off before the shapes
    /// are read.
    ///
    /// That markup is Moe's own bookkeeping — the ledger parser reads it and
    /// removes it, so it is never words reaching anybody — but `moe-open` is
    /// the exact shape of a plug-in narrating itself, and treating it as one
    /// costs the person the whole reminder the trailer was riding on.
    /// Measured: 21 of `LedgerTest`'s 40 went red the first time this strip
    /// was missing, and again when it ran in the wrong order.
    ///
    /// The second alternative is an opener that never closes — a truncated
    /// delivery or a model typo — which `deliver.py`'s `read_trailers`
    /// already consumes to the end of the text for the same reason.
    private static func withoutTrailerMarkup(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\[\[.*?\]\]|\[\[.*"#,
                                                options: [.dotMatchesLineSeparators])
        else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: " ")
    }

    /// The conservative half: a shape in the FIRST LINE of something that does
    /// not read as a sentence.
    ///
    /// Three conditions, each load-bearing and each mirrored in `deliver.py`'s
    /// `is_machinery` in the same order. A notice LEADS with its machinery, it
    /// is SHORT, and it does not end in sentence punctuation. An answer that
    /// mentions a file name or a path has all three the other way round, and
    /// dropping is the whole message — so the side that bins something
    /// silently is the side that has to be sure.
    private static func leadsWithSomethingOnlyAMachineHas(_ trimmed: Substring) -> Bool {
        // The markup comes off BEFORE the marks do — the caller's `bare` has
        // already lost a leading "[" to the mark-stripper, which would leave
        // `moe-open: …` looking exactly like a plug-in narrating itself.
        let stripped = withoutTrailerMarkup(String(trimmed))
        // The OPENER keeps its marks; `head` has them off. The glyph gate
        // below reads the opener, because a mark (⚠ ♻ ❗) is itself a
        // pictograph and taking it off first would make
        // `⚠ moe-ledger — recalled 2` look like a person's own line.
        let opener = String(stripped.prefix { $0 != "\n" })
            .trimmingCharacters(in: .whitespaces)
        var bare = Substring(stripped)
        while let c = bare.first, marks.contains(c) { bare = bare.dropFirst() }
        let head = String(bare.prefix { $0 != "\n" })
            .trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, head.count <= 200 else { return false }
        if readsAsASentence(head) { return false }
        guard narratesItself(opener) else { return false }
        return notMoesWords(head) != nil
    }

    /// Does this line OPEN the way machinery opens — with a pictograph?
    ///
    /// Added 2026-09-15, mirroring `_narrates_itself` in `deliver.py`. The G3
    /// email review ran real answers through the shape table and five were
    /// DROPPED — each a reply a person had asked for, gone, with no trace
    /// anywhere they would look:
    ///
    ///     "…(option 1/3)\nUnited 7am, $320."
    ///     "Here's what I found (page 2/5)"
    ///     "total_cost: $412\nThat includes tax."
    ///     "check_in_time: 3pm"
    ///     "Open /settings in the app, then tap Email"
    ///
    /// **A false positive here is worse than a false negative, and not
    /// narrowly.** A machinery line that gets through is one ugly bubble; an
    /// answer that is dropped is a person asking Moe something and getting
    /// silence. The shapes were already "narrow on purpose" and were still
    /// not narrow enough, because no shape can tell `total_cost:` from
    /// `gmail_status:` by reading the identifier. The GLYPH tells them apart,
    /// and it is not a heuristic — it is what the emitting code puts there.
    ///
    /// Unicode's Symbol-other category is the test, so a glyph nobody has
    /// used yet counts without being listed. `…` is punctuation, not a
    /// symbol, which is what saves the first line above.
    ///
    /// One narrow exception: a bare tool id ending in an ellipsis and nothing
    /// else (`moe_away_status…`) is in the corpus with no glyph, because a
    /// tool registered without an emoji renders that way. A line that is ONLY
    /// an identifier and an ellipsis is nobody's answer; an identifier
    /// followed by a colon and a VALUE is data, and is delivered.
    static func narratesItself(_ opener: String) -> Bool {
        var bare = Substring(opener)
        while let c = bare.first, marks.contains(c) { bare = bare.dropFirst() }
        let rest = bare.trimmingCharacters(in: .whitespaces)
        if let re = try? NSRegularExpression(pattern: bareTracePattern),
           re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil {
            return true
        }
        // The FIRST scalar that is neither space nor a variation selector.
        // Read per SCALAR, not per Character: an emoji Character can be a
        // whole cluster (a base plus U+FE0F, or a ZWJ sequence), and only its
        // base carries the category.
        for scalar in opener.unicodeScalars {
            if scalar.properties.isWhitespace || scalar == "\u{fe0f}" { continue }
            return scalar.properties.generalCategory == .otherSymbol
        }
        return false
    }

    /// See `narratesItself`. Kept beside `shapes` so the two files' patterns
    /// stay comparable character for character.
    static let bareTracePattern = #"^[a-z][a-z0-9]*(?:[_-][a-z0-9]+)+\s*(?:\.\.\.|…)\s*$"#

    /// True when this line ends the way a person's sentence ends.
    ///
    /// An ELLIPSIS does not count, and that exception is the whole reason this
    /// is a function rather than one `hasSuffix` call: `📧 gmail_status...`
    /// ends in a full stop by the letter, and the first cut of this rule let
    /// every ellipsis-terminated tool trace through on exactly that
    /// technicality — two of the six lines it was written for. A trailing `…`
    /// is a thing that has been interrupted, not a thing that has been said.
    private static func readsAsASentence(_ head: String) -> Bool {
        if head.hasSuffix("...") || head.hasSuffix("…") { return false }
        return head.hasSuffix(".") || head.hasSuffix("?") || head.hasSuffix("!")
    }
}
