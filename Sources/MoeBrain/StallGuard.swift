import Foundation

/// A reply that promises work and then ends the turn.
///
/// Measured on 2026-09-23 at 21:39:09Z: the brain's last words were "Good,
/// the browser's loading Google Flights now — one sec while I set the Hanoi
/// to Kunming search for around October 30th." with `stop_reason: end_turn`
/// and no tool call after it. The person was told Moe was working, and Moe
/// had stopped. It was 1 of 1,071 end_turn replies in the transcripts that
/// day — rare, and the worst kind of failure, because it looks like success.
///
/// This is the harness's half, not the prompt's: Moe is provider-agnostic,
/// and a rule in one model's instructions does nothing for the next one. When
/// a turn ends on a first-person promise of *imminent* work, with nothing
/// asked of the person and no step running, the Conductor sends the brain
/// one continuation (`note(for:)`). One, per turn the person started — the
/// continuation's own turn never earns another, so this cannot loop.
///
/// The classifier is deliberately narrow. It reads only the closing sentence,
/// it never fires on a question, and it never fires on an offer that waits
/// for the person ("tell me which and I'll check", "want me to…?"): those are
/// a turn correctly handed back, and prodding one would make Moe act on a
/// choice nobody made.
public enum StallGuard {

    /// The closing sentence, when it promises work the reply did not do.
    /// Nil for everything else.
    ///
    /// A promise is a first-person subject with a verb of doing work
    /// ("let me pull", "I'll now fill", "I'm going to open", "one sec while
    /// I set", "working on it"), in the last sentence, with nothing after it
    /// that shows the work was done ("Let me summarise: VietJet, 10:05").
    /// Rhetoric ("let me be honest", "let me put it this way"), words
    /// addressed to the person ("don't let me forget", "hang on to the
    /// email", "let me know"), and wrap-ups ("I'll now stop") are not.
    public static func promise(in reply: String) -> String? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The last paragraph. A question anywhere in it hands the turn back.
        let lastParagraph = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? text
        guard !lastParagraph.contains("?") else { return nil }

        guard let sentence = lastSentence(of: lastParagraph) else { return nil }
        let s = normalised(sentence)

        // An offer that waits on the person is a turn handed back, not a stall.
        if offerCues.contains(where: { matches($0, s) }) { return nil }
        // "It took one second" is a report, not a promise.
        if matches(#"\b(took|in|within|for|about|than|every|after|last|only|under|over) (one|just a|a) (sec|second|moment|min|minute)"#, s) {
            return nil
        }
        for cue in promiseCues {
            guard let r = s.range(of: cue, options: .regularExpression) else { continue }
            // The work shown after the promise: "let me summarise: …",
            // "here's what I found — …". A colon with something after it is
            // the reply delivering what it announced.
            let after = s[r.upperBound...]
            if let colon = after.firstIndex(of: ":"),
               after[after.index(after: colon)...].trimmingCharacters(in: .whitespaces).count >= 3 {
                return nil
            }
            return sentence
        }
        return nil
    }

    /// What the brain is sent, once, when a reply stalls on `promise`.
    /// Worded like the other background notes, so the model reads it as the
    /// app speaking and not the person.
    public static func note(for promise: String) -> String {
        let quoted = promise.count > 240 ? String(promise.prefix(240)) + "…" : promise
        return """
        (Background note, not from the person: you said you'd do this — "\(quoted)" — \
        but the turn ended with nothing running. Carry on and do it now, or say plainly \
        why you can't. Do not mention this note or apologise for the pause.)
        """
    }

    // MARK: - The cues

    /// Verbs of doing work — the thing a promise says is about to happen.
    /// Deliberately not "be", "put", "say", "explain", "summarise", "know",
    /// "stop", "think": those are rhetoric or a wrap-up, not work.
    static let workVerbs = [
        "check", "look", "search", "find", "pull", "open", "load", "grab", "fetch",
        "run", "try", "retry", "set", "start", "get", "book", "send", "fill", "go",
        "dig", "see", "take", "write", "draft", "make", "compare", "read", "scan",
        "navigate", "click", "type", "enter", "head", "jump", "hop", "spin", "kick",
        "fire", "bring", "reload", "refresh", "finish", "complete", "submit", "sort",
        "move", "schedule", "add", "create", "update", "fix", "install", "download",
        "upload", "track", "confirm", "verify", "test", "figure", "work", "research",
        "pick", "review", "compile", "gather", "collect", "poke", "peek", "query",
        "call", "message", "text", "email", "reply", "save", "copy", "switch",
        "launch", "handle", "tackle", "log", "sign", "select", "choose", "change",
        "adjust", "plug", "punch", "queue", "grab", "hunt", "chase", "ping",
    ].joined(separator: "|")

    /// First-person promises of work about to happen. Matched against the
    /// closing sentence, lowercased, with curly apostrophes straightened.
    static var promiseCues: [String] {
        let v = "(\(workVerbs))(s|es|ing|ed)?"
        return [
            // "one sec while I…", "just a moment", "give me a minute" — the
            // speaker asking for time, which is itself the promise
            #"(^|[^a-z])(one|just a|give me a|gimme a|give me one) (sec|second|moment|min|minute|mo)\b"#,
            // "hang on while I…", "hold on" — never "hang on to the email"
            #"(^|[—–,;:-] ?|\b(ok|okay|right|good|great|sure|so),? )(hang|hold) on\b(?! to\b)"#,
            #"^(hang|hold) on\b(?! to\b)"#,
            #"\bbear with me\b"#,
            // "let me pull that up" — never "don't let me forget"
            #"(?<!n't )(?<!not )(?<!never )\blet me (quickly |just |now |go ahead and )?\#(v)\b"#,
            // "I'll now fill in the form", "I'll go ahead and book it",
            // "I'll get started on that"
            #"\bi'?ll (now|just now|go ahead and|quickly|right away) \#(v)\b"#,
            #"\bnow,? i'?ll \#(v)\b"#, #"\bnext,? i'?ll \#(v)\b"#,
            #"\bi'?ll (get started|get going|get on it|get on that|get to it|get to work|start on|start with|start by|kick (it|that|this) off)\b"#,
            #"\bi'?m (now |just )?(going to|gonna|about to) (now |go ahead and |quickly )?\#(v)\b"#,
            // "Checking now." "Working on it." "Starting the search." — a
            // short sentence that opens on the work itself
            #"^(ok(ay)?,? |right,? |sure,? |got it,? |on it,? |alright,? )?(working on (it|that|this|the)|starting (on |with )?(it|that|this|the)|checking|searching|pulling|opening|loading|grabbing|fetching|running|setting up|firing up|getting (it|that|the)|digging|looking (it|that|into|for|up))\b[^,]{0,50}$"#,
        ]
    }

    /// Offers and conditionals: the next move is the person's.
    static let offerCues: [String] = [
        #"\blet me know\b"#,
        #"\bif (you|that|this|it|they|so|not|needed|useful)\b"#,
        #"\btell me\b"#,
        #"\bwant me to\b"#, #"\bshould i\b"#, #"\bshall i\b"#, #"\bwould you\b"#,
        #"\bsay the word\b"#, #"\bjust say\b"#,
        #"\b(once|when|whenever) you\b"#,
        #"\bhappy to\b"#,
        #"\bnext time\b"#,
    ]

    static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Reading the sentence

    /// The final sentence, with trailing markdown and quotes taken off.
    static func lastSentence(of paragraph: String) -> String? {
        var p = paragraph
        let trailing = CharacterSet(charactersIn: " *_`\"'”’)]").union(.whitespaces)
        while let last = p.unicodeScalars.last, trailing.contains(last) { p.removeLast() }
        guard !p.isEmpty else { return nil }
        // The last sentence starts after the last terminator that is
        // followed by a space (". ", "! ", "… "), so "3.5 km" and "google.com"
        // do not split. A terminator at the very end belongs to it.
        var body = Substring(p)
        if let end = body.last, ".!…:".contains(end) { body = body.dropLast() }
        var start = body.startIndex
        var i = body.startIndex
        while i < body.endIndex {
            let next = body.index(after: i)
            if ".!…".contains(body[i]), next < body.endIndex, body[next].isWhitespace {
                start = next
            }
            i = next
        }
        let sentence = body[start...]
        let clean = sentence.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    static func normalised(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }
}
