import Foundation

/// "Is this for me?" — inside the follow-up window only. VOICE-PLAN.md §4.3.
///
/// After "Hey Moe" the first turn is always Moe's, and a held key always
/// is; the window is where a person might be talking to someone else in
/// the room. Nobody sells this decision, and the research consensus
/// (Apple's follow-up papers, Alexa's follow-up mode) is a small fusion of
/// cheap signals over conversation state, failing closed: a turn that is
/// not clearly for Moe never reaches the brain.
///
/// Pure: the host gathers the signals, this weighs them. Thresholds are
/// starting points to be tuned on Moe's own turn traces (§7). One cue is
/// never enough on its own except the name; casual room speech starts
/// with "so", "okay" and "and" and is full of "you".
public enum Addressee {

    /// `done` is the one a word list cannot find: "that's all", "we're
    /// finished", "לא מדבר איתך" — said to Moe, and meaning stop. There is
    /// no published model, corpus or benchmark for this anywhere (surveyed
    /// 2026-09-03), so the authority is the on-device model, which reads
    /// meaning in whatever language it was said. The English phrases below
    /// are a fast path that skips the model call, never the mechanism.
    public enum Verdict: Equatable, Sendable { case directed, notDirected, unsure, done }

    public struct Signals: Equatable, Sendable {
        /// The transcript. The name may still be in it; `namedMoe` says
        /// whether the host stripped one off the front.
        public var text: String
        /// The turn began with, or contained, Moe's name (any spelling).
        public var namedMoe: Bool
        /// Seconds from Moe's reply ending to this speech *starting*. Nil
        /// when unknown (a barge-in; a reply that was not spoken).
        public var secondsSinceReply: Double?
        /// Moe's reply ended in a question: an answer is expected.
        public var moeAskedQuestion: Bool
        /// This turn's loudness against the utterance that opened the
        /// session (speech-only RMS ratio). Someone who turned to a
        /// colleague is quieter at the microphone. Nil when unknown.
        public var levelRatio: Float?
        /// Cosine similarity to the enrolled owner voice; nil when there is
        /// no enrolment. A soft signal by default (§4.5).
        public var ownerScore: Float?
        /// How long the speech lasted.
        public var speechSeconds: Double
        /// The words are English, so the lexical cues below mean something.
        /// In any other language only the name, the room and the clock are
        /// read: the openers, the second person and the goodbyes are an
        /// English vocabulary, and scoring a French follow-up against them
        /// says "not for Moe" about every sentence.
        public var english: Bool

        public init(text: String, namedMoe: Bool = false, secondsSinceReply: Double?, moeAskedQuestion: Bool,
                    levelRatio: Float? = nil, ownerScore: Float? = nil, speechSeconds: Double = 0,
                    english: Bool = true) {
            self.text = text
            self.namedMoe = namedMoe
            self.secondsSinceReply = secondsSinceReply
            self.moeAskedQuestion = moeAskedQuestion
            self.levelRatio = levelRatio
            self.ownerScore = ownerScore
            self.speechSeconds = speechSeconds
            self.english = english
        }
    }

    // MARK: - Lexical cues

    /// How Alfie's name comes out of a recogniser.
    public static let names: Set<String> = ["alfie", "alfy", "alfee", "alfi", "alphie"]

    /// A request's first word: a question word or an imperative.
    static let requestOpeners: Set<String> = [
        "what", "when", "where", "who", "why", "how", "which", "whose",
        "is", "are", "was", "were", "can", "could", "would", "should", "do", "does", "did", "will",
        "tell", "show", "open", "set", "remind", "play", "send", "read", "find", "search", "call", "text",
        "add", "start", "stop", "turn", "make", "give", "check", "look", "go", "help", "explain",
        "summarize", "summarise", "translate", "repeat", "say", "write", "draft", "schedule", "book",
        "cancel", "delete", "move", "change", "put", "get", "bring", "list", "count", "calculate",
        "convert", "skip", "pause", "continue", "resume", "undo", "redo", "close", "save", "print",
        "please", "let's", "lets",
    ]
    /// Words casual speech starts with, to anyone. Worth a little only.
    static let discourseOpeners: Set<String> = [
        "and", "also", "now", "then", "okay", "ok", "so", "actually", "wait", "no", "yes", "yeah",
        "well", "um", "uh", "oh", "hey", "but",
    ]
    /// One- or two-word commands that are complete on their own.
    static let shortCommands: Set<String> = [
        "stop", "louder", "quieter", "next", "back", "again", "repeat", "cancel", "pause", "continue",
        "resume", "skip", "undo", "faster", "slower", "wait", "enough", "go on", "say again", "one more",
        "go back", "read it", "do it", "send it", "open it", "yes please", "no thanks", "never mind",
    ]
    static let secondPerson: [String] = ["you", "your", "you're", "yours", "you've", "you'll", "you'd"]
    /// Talking about a third party, or narrating — to someone else.
    static let aside: [String] = ["he said", "she said", "they said", "i told", "we're gonna", "we are going",
                                  "let me just", "hold on", "one sec", "one second", "hang on", "sorry what",
                                  "as i was saying", "anyway", "i'll be right", "be right there", "coming"]

    /// A score above zero leans "for Moe". Roughly a logit: the name or a
    /// bare command reaches `directedAbove` on its own; nothing else does,
    /// because a request to Moe and a request to the person next to you are
    /// the same sentence ("can you send that to Sam"). What separates those
    /// is the room, not the words: who spoke, how far away, and — when the
    /// Mac has it — the on-device judge, which sees what Moe just said.
    /// Words that appear in almost any English sentence long enough to be a
    /// request. Not a grammar — a presence test.
    static let englishFunctionWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "do", "does",
        "did", "can", "could", "will", "would", "should", "i", "you", "it",
        "me", "my", "your", "we", "they", "he", "she", "this", "that",
        "what", "when", "where", "who", "how", "why", "which",
        "to", "of", "in", "on", "for", "with", "at", "from", "about", "and",
        "or", "but", "not", "no", "yes", "up", "out", "off", "please",
        "have", "has", "had", "get", "got", "just", "some", "any", "all",
        "there", "here", "now", "then", "if", "so", "as", "by", "into",
    ]

    /// Letters English does not use, but its Latin-script neighbours do.
    /// Deliberately excludes the accented vowels English borrows in
    /// "café", "naïve", "résumé".
    static let foreignLetters = Set("çñßøåæœðþłśźżčšžğıăşțđ")

    /// Does this look like the recogniser slipped into another language?
    ///
    /// It happens because the language setting is weaker than it sounds:
    /// FluidAudio's filter partitions by Unicode *script*, so asking for
    /// English rules out Cyrillic and Greek and nothing else — French,
    /// Romanian and Polish come back through an English setting unchanged.
    /// Observed on this Mac: "ça ne veut rien" and "Acum z iszym", both
    /// answered as though they were requests.
    ///
    /// Two independent signs, either of which is enough:
    ///
    /// - a letter English does not use; or
    /// - three or more words and not one of them an English function word.
    ///   Real requests are almost never like this ("what is the weather",
    ///   "open my notes", "remind me to call") — an English sentence of any
    ///   length leans on those words constantly.
    ///
    /// It is a *penalty*, not a veto, and it never applies to a turn that
    /// named Moe: the name is a sound rather than a word, someone who says
    /// it meant to, and this must not be the thing that stops a bilingual
    /// household using their own assistant.
    static func looksForeign(_ text: String, words: [String]) -> Bool {
        if text.lowercased().contains(where: { foreignLetters.contains($0) }) { return true }
        guard words.count >= 3 else { return false }
        return !words.contains(where: { englishFunctionWords.contains($0) })
    }

    public static func score(_ s: Signals) -> Float {
        let norm = TurnPolicy.normalise(s.text)
        var words = norm.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return -2 }
        var score: Float = 0

        // Lexical. The name is read in every language — it is a sound,
        // not a word — and the rest only where the vocabulary applies.
        let named = s.namedMoe || words.contains(where: { names.contains($0) })
        if named { score += 2 }
        guard s.english else { return score + roomAndClock(s) }
        // The request starts after the name and any "okay, um, so".
        while let first = words.first, names.contains(first) || discourseOpeners.contains(first) {
            words.removeFirst()
            if words.count == 1 { break }
        }
        if let first = words.first, requestOpeners.contains(first) { score += 1 }
        if words.contains(where: { secondPerson.contains($0) }) { score += 0.25 }
        if s.text.trimmingCharacters(in: .whitespaces).hasSuffix("?") { score += 0.25 }
        if shortCommands.contains(norm) || shortCommands.contains(words.joined(separator: " ")) { score += 1.5 }
        if aside.contains(where: { norm.contains($0) }) { score -= 1.5 }
        // Nobody monologues at an assistant in a follow-up window: they
        // dictate a message, talk on the phone, or think out loud. Measured
        // here — a 33-word passage of the user describing Moe to somebody
        // else scored 0.2 and was kept, and its continuation was answered.
        // The name or a question mark rescues a genuinely long request.
        // Unless it started as soon as Moe finished. Somebody who begins
        // within two seconds of the reply is answering it, and people
        // answer at length; length is evidence of a monologue only when
        // there was a gap first. Measured 2026-09-07: four 27–52-word
        // answers that began within two seconds of the reply were all for
        // Moe, and the one this rule sank had been read correctly at
        // confidence 0.98.
        let continuing = (s.secondsSinceReply ?? .infinity) <= 2
        // Nor when Moe had just asked something: a question invites a long
        // answer. 2026-09-29 20:45: Moe asked "Want me to build that
        // version?", the owner answered in 77 words four seconds later, and
        // the length rule dropped it; they said it all again on the key.
        if !continuing, !s.moeAskedQuestion {
            if words.count > 24 { score -= 1.5 }
            else if words.count > 16 { score -= 0.5 }
        }
        if !named, looksForeign(s.text, words: words) { score -= 1.5 }

        return score + roomAndClock(s)
    }

    /// The signals that mean the same in every language: when it was said,
    /// how loud, and whether it sounded like the person Moe knows.
    private static func roomAndClock(_ s: Signals) -> Float {
        var score: Float = 0
        if s.moeAskedQuestion { score += 1 }
        if let since = s.secondsSinceReply {
            if since <= 2 { score += 0.5 } else if since > 6 { score -= 0.5 }
        }
        // Loud enough is nothing; quiet is a lean away.
        if let ratio = s.levelRatio {
            if ratio < 0.35 { score -= 1.5 } else if ratio < 0.6 { score -= 0.5 }
        }
        if let owner = s.ownerScore {
            // A strong match is as good as the name: 2026-09-23 14:31, owner
            // 0.83 at 1.6× their level, 30 words — dropped as "not for Moe".
            if owner >= 0.8 { score += 1.5 } else if owner >= 0.6 { score += 1 } else if owner < 0.4 { score -= 1.5 }
        }
        return score
    }

    /// The decision from the cheap signals alone. `unsure` is the band in
    /// which the host asks the on-device model.
    public static func verdict(_ s: Signals, directedAbove: Float = 1.5, notDirectedBelow: Float = -1.0) -> Verdict {
        let x = score(s)
        if x >= directedAbove { return .directed }
        if x <= notDirectedBelow { return .notDirected }
        return .unsure
    }

    /// What to do with an `unsure` turn on a Mac that cannot ask the model.
    ///
    /// Dropping every ambiguous turn would make the window useless — a
    /// plain "read it again" is ambiguous by these rules — so a turn that
    /// looks like a request with nothing pointing away is taken. The cost
    /// is that a request said to a person in the room, while the window is
    /// open, may be answered; the acoustic and owner signals are what
    /// catch that, and the judge is what settles it where it exists.
    public static func leansDirected(_ s: Signals, above: Float = 0.75) -> Bool {
        if ownerAtTheMic(s) { return true }
        // Outside English there is no request shape to recognise, so the
        // question is only whether anything points away: a turn at the
        // right distance, from the right voice, soon after Moe spoke, is
        // taken. Otherwise the window would swallow every sentence.
        return score(s) >= (s.english ? above : 0)
    }

    /// Whether a turn whose voice did not match the one that opened the
    /// conversation is still plainly the person's, so the anchor must not
    /// drop it unheard.
    ///
    /// The anchor gate had fired once from 09-16 to 09-29, and was wrong:
    /// 2026-09-29 22:08, 76 words of the owner's, loud, scored 0.22 against
    /// a conversation whose own turns scored 0.49–0.86 — dropped before the
    /// words had a vote. A single embedding of the turn's tail is too noisy
    /// to overrule the room's other evidence alone: loud as the person
    /// usually is, or matching their enrolled voice, and the words decide.
    public static func anchorOverruled(_ s: Signals) -> Bool {
        if let level = s.levelRatio, level >= 0.6 { return true }
        if let owner = s.ownerScore, owner >= 0.5 { return true }
        return false
    }

    /// The person Moe knows, at the distance they talk to it from.
    ///
    /// On a Mac without the on-device judge — and on the owner's, the model
    /// was "still downloading" for the whole of 09-16 to 09-29 — every
    /// `unsure` turn was settled by the words alone, and six of the owner's
    /// own requests were dropped, among them answers of 65, 77 and 136
    /// words. Of the 23 window verdicts in that fortnight, the owner's were
    /// all at 0.48× their level or louder with an owner score of 0.54 or
    /// more (or none measured, at 0.93× and up); every one of the others
    /// was at 0.37× or quieter, or scored 0.23 or less as the owner.
    public static func ownerAtTheMic(_ s: Signals) -> Bool {
        guard let level = s.levelRatio else { return false }
        if let owner = s.ownerScore { return level >= 0.45 && owner >= 0.5 }
        // No voice match to go on: only right at the microphone. A person
        // explaining Moe to somebody in the room at their usual distance
        // (`aMonologueInTheWindowIsNotForMoe`) must still not be answered.
        return level >= 0.9
    }

    // MARK: - Closing and resolving the window

    /// What may surround the name in a goodbye.
    static let closerWords: Set<String> = [
        "thanks", "thank", "you", "that's", "thats", "all", "it", "ok", "okay", "cool", "great", "bye",
        "goodbye", "cheers", "a", "lot", "so", "much", "for", "now", "good", "perfect", "nice", "never",
        "mind", "nevermind", "done", "we're", "were", "i'm", "im", "fine", "then", "that", "is", "will",
        "be", "enough", "sleep", "go", "to", "stop", "listening", "later", "see", "ya",
    ]
    static let closeCores: [String] = ["thanks", "thank", "all", "it", "bye", "goodbye", "cheers", "done",
                                       "mind", "nevermind", "sleep", "stop", "enough", "later"]

    /// "Thanks Moe" and its kin: the name at the end (or start) of a short
    /// goodbye made only of goodbye words. Never "thanks" alone — that
    /// closes nothing — and never a request that happens to thank.
    public static func isClosePhrase(_ text: String) -> Bool {
        let words = TurnPolicy.normalise(text).split(separator: " ").map(String.init)
        guard (2...7).contains(words.count) else { return false }
        guard let last = words.last, let first = words.first else { return false }
        let rest: [String]
        if names.contains(last) { rest = Array(words.dropLast()) }
        else if names.contains(first) { rest = Array(words.dropFirst()) }
        else { return false }
        guard !rest.isEmpty, rest.allSatisfy({ closerWords.contains($0) }) else { return false }
        return rest.contains { closeCores.contains($0) }
    }

    /// A fast path only, and only for English. What actually decides is
    /// `AddresseeJudge`; this exists so the commonest phrases cost nothing.
    ///
    /// "I'm not talking to you", "stop", "never mind": said *to* Moe, and
    /// the one thing it can mean is that Moe should stop and let go — not
    /// a question to answer. Unlike `isClosePhrase` the name is optional,
    /// because this is what people say when Moe has butted in and they are
    /// not being polite about it.
    public static func isDismissal(_ text: String) -> Bool {
        let norm = TurnPolicy.normalise(text)
        guard !norm.isEmpty else { return false }
        let words = norm.split(separator: " ").map(String.init)
        guard words.count <= 8 else { return false }
        // Strip a trailing name: "not talking to you, Moe".
        var body = words
        if let last = body.last, names.contains(last) { body.removeLast() }
        let phrase = body.joined(separator: " ")
        if dismissals.contains(phrase) { return true }
        // "I'm not talking to you" / "wasn't talking to you" and kin.
        if phrase.contains("not talking to you") || phrase.contains("not talking to moe")
            || phrase.contains("wasn't talking to you") || phrase.contains("wasnt talking to you")
            || phrase.contains("not asking you") || phrase.contains("not for you") {
            return true
        }
        return false
    }

    static let dismissals: Set<String> = [
        "stop", "stop it", "stop talking", "be quiet", "quiet", "shush", "shut up",
        "never mind", "nevermind", "forget it", "forget about it", "cancel", "cancel that",
        "not you", "nothing", "no nothing", "sorry not you", "ignore that", "ignore me",
        "go away", "leave it", "wait", "hold on", "one second", "one sec", "go to sleep",
        "stop listening", "that's enough", "thats enough", "enough",
    ]

    /// Just the name ("Moe?", "hey Moe"): what resolves an `unsure` turn
    /// kept from a moment ago.
    public static func isNameOnly(_ text: String) -> Bool {
        let words = TurnPolicy.normalise(text).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 3, words.contains(where: { names.contains($0) }) else { return false }
        return words.allSatisfy { names.contains($0) || ["hey", "hi", "yo", "um", "uh", "so"].contains($0) }
    }
}
