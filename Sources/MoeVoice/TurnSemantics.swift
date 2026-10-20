import Foundation

/// What the *words* say about a pause: has the person said something an
/// assistant can act on, or are they plainly still going?
///
/// Smart Turn hears the audio; it cannot read. Its training data made every
/// complete clause "complete" by construction (research-endpointing.md §1.3),
/// and a fine-tune on synthetic clause cuts taught it words rather than
/// prosody (smart-turn-ft.md). So the words are read here, as a separate
/// vote that `EndpointPolicy` fuses with the score, the pause so far and the
/// turn's length.
///
/// Two readers, cheapest first:
/// - **rules** (`read(_:)`), pure and instant: how the words end (a
///   conjunction, a preposition, a determiner, an auxiliary, a question word,
///   a subject with no verb after it), an utterance that is only an opener
///   ("so", "can you", "I was thinking"), and the closed set of answers that
///   are finished by themselves ("yes", "not yet", "go ahead");
/// - **a model** (`Moe/Voice/TurnSemanticJudge`, Apple's on-device model),
///   asked only when the rules have no opinion, under a deadline, and never
///   waited for when it is not there (`Reading.unknown` is the fail-open).
///
/// English only, like the dangler list it grows from; the host does not ask
/// for other languages.
public enum TurnSemantics {

    public enum Reading: String, Codable, Equatable, Sendable {
        /// The words cannot stand as a turn: more is coming.
        case unfinished
        /// The words are a whole turn by themselves ("yes", "go ahead").
        case finished
        /// A clause that could end here or go on — most requests. The
        /// audio and the pause decide.
        case unknown
    }

    /// Where a reading came from, for the trace and the log.
    public enum Source: String, Codable, Equatable, Sendable { case rules, model }

    // MARK: - Word classes

    /// A clause cannot end on these: something must follow. Conjunctions,
    /// prepositions, determiners and possessives, auxiliaries and modals,
    /// complementisers and relative words. Deliberately **not** words that
    /// can close a clause ("it", "this", "that one", "up", "out", "now").
    static let needsMore: Set<String> = Set([
        // conjunctions and connectives
        "and", "but", "or", "nor", "so", "because", "cause", "cuz", "unless", "although",
        "whereas", "while", "whether", "if", "then", "plus", "also", "except",
        // prepositions that take an object
        "to", "of", "with", "for", "in", "on", "at", "by", "from", "into", "onto", "about",
        "than", "as", "like", "via", "per", "between", "among", "through", "toward", "towards",
        "without", "within", "including", "regarding", "until", "till", "during", "against",
        // determiners and possessives that need a noun
        "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "every", "each",
        "these", "those", "whose", "several",
        // auxiliaries and modals left without their verb
        "is", "are", "was", "were", "be", "been", "being", "am", "can", "could", "would",
        "should", "will", "shall", "may", "might", "must", "don't", "doesn't", "didn't",
        "can't", "won't", "isn't", "aren't", "i'm", "it's", "you're", "we're", "they're",
        "i'll", "you'll", "we'll", "i'd", "i've", "we've",
        // complementisers, relative and question words at the end of a clause
        "that", "which", "who", "whom", "where", "when", "what", "how", "why",
        // a subject with nothing after it ("and then I")
        "i",
        // words that modify what follows
        "very", "really", "quite", "not", "just", "even", "actually", "basically", "literally",
        // "want to" and "going to", spoken
        "wanna", "gonna", "gotta", "hafta", "want", "wanted", "need", "trying", "supposed", "able",
        // hesitation
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm",
    ])

    /// Two-word endings that need more even though their last word alone
    /// might not ("such as", "and then", "kind of").
    static let needsMorePairs: Set<String> = Set([
        "such as", "and then", "kind of", "sort of", "you know", "i mean", "let me", "or maybe",
        "and also", "what about", "how about", "in case", "so that", "even though", "as if",
        "rather than", "instead of", "out of", "because of", "next to", "all of", "some of",
        "one of", "most of", "none of", "any of", "each of", "in front",
    ])

    /// Utterances that are only a way in: nothing an assistant can act on
    /// has been said yet.
    static let openers: Set<String> = Set([
        "so", "okay so", "ok so", "well", "alright so", "right so", "hey", "hey moe", "moe",
        "so um", "um so", "okay um", "and", "and also", "also", "oh and", "oh also",
        "can you", "could you", "would you", "will you", "can we", "could we", "i want", "i need",
        "i'd like", "i would like", "i was thinking", "let me", "let's", "what about",
        "how about", "tell me", "i was wondering", "quick question", "one more thing",
        "and another thing", "wait", "hold on", "hang on", "okay and", "so what", "and then",
    ])

    /// Answers that are a whole turn by themselves. Matched on the whole
    /// utterance, never on its end ("…and yes" is not finished).
    static let wholeAnswers: Set<String> = Set([
        "yes", "yeah", "yep", "yup", "no", "nope", "nah", "sure", "okay", "ok", "right",
        "correct", "exactly", "absolutely", "definitely", "of course", "of course not",
        "not yet", "not now", "not really", "why not", "me too", "i think so", "i guess so",
        "i don't think so", "go ahead", "do it", "okay do it", "yes do it", "yeah do it",
        "yes please", "no thanks", "no thank you", "thanks", "thank you", "thank you moe",
        "thanks moe", "that's right", "that's it", "that's all", "that's fine", "that's good",
        "sounds good", "perfect", "great", "never mind", "nevermind", "forget it", "cancel",
        "cancel that", "stop", "yeah go ahead", "yes go ahead", "okay go ahead", "please do",
        "send it", "do that", "the first one", "the second one", "the third one", "the last one",
        "both", "neither", "either", "all of them", "none of them", "good night", "goodbye", "bye",
    ])

    // MARK: - Reading

    /// The rules' reading of `text` (any case or punctuation).
    ///
    /// - A punctuating recogniser's ellipsis or trailing comma says more is
    ///   coming; its full stop or question mark is *not* taken as finished —
    ///   recognisers put one on every clause they close, which is exactly the
    ///   pause this exists for.
    public static func read(_ text: String) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        if trimmed.hasSuffix("…") || trimmed.hasSuffix("...") || trimmed.hasSuffix(",")
            || trimmed.hasSuffix("-") || trimmed.hasSuffix("—") { return .unfinished }
        let words = TurnPolicy.words(trimmed)
        guard let last = words.last else { return .unknown }
        let whole = words.joined(separator: " ")
        if wholeAnswers.contains(whole) { return .finished }
        if openers.contains(whole) { return .unfinished }
        if needsMore.contains(last) { return .unfinished }
        if words.count >= 2, needsMorePairs.contains(words.suffix(2).joined(separator: " ")) { return .unfinished }
        if TurnPolicy.completeness(of: trimmed) == .incomplete { return .unfinished }
        return .unknown
    }

    /// The words as a table key: case, punctuation and spacing do not
    /// make two texts different.
    public static func key(_ text: String) -> String { TurnPolicy.normalise(text) }

    /// A model's one word, read. Anything that is not clearly one of the two
    /// answers is no answer (`nil`), and the rules' reading stands.
    public static func parseModelAnswer(_ answer: String) -> Reading? {
        let word = answer.uppercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if word.hasPrefix("DONE") || word.hasPrefix("FINISHED") || word.hasPrefix("COMPLETE") { return .finished }
        if word.hasPrefix("MORE") || word.hasPrefix("UNFINISHED") || word.hasPrefix("INCOMPLETE") { return .unfinished }
        return nil
    }

    /// The reading the policy uses: the rules' when they have one, else the
    /// model's when it answered in time, else unknown.
    public static func combine(rules: Reading, model: Reading?) -> (Reading, Source) {
        if rules != .unknown { return (rules, .rules) }
        if let model { return (model, .model) }
        return (.unknown, .rules)
    }
}
