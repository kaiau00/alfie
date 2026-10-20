import Foundation

/// The rules of turn-taking that read text and time, not audio.
/// VOICE-PLAN.md §4.2. Pure, so each is a test.
///
/// The audio-side signals (the endpointer's token, the turn model's
/// verdict, the VAD's silence) arrive from the host; these decide what a
/// transcript's *shape* says about whether the person is done, and which
/// short noises are not turns at all.
public enum TurnPolicy {

    // MARK: - Backchannels

    /// "mm-hmm", "yeah", "okay": said *to* a speaker, not *as* one. In a
    /// follow-up window they must neither end Moe's turn nor start yours.
    public static let backchannels: Set<String> = [
        "mm", "mmm", "mhm", "mm-hmm", "mmhmm", "uh-huh", "uhuh", "uh huh", "hmm", "hm",
        "yeah", "yep", "yup", "yes", "ok", "okay", "right", "sure", "cool", "nice",
        "i see", "got it", "oh", "ah", "aha", "huh", "wow", "true", "alright", "all right",
    ]

    /// A short utterance that is one of the backchannel forms.
    ///
    /// - Parameters:
    ///   - text: the transcript, any case or punctuation.
    ///   - seconds: how long the speech lasted; anything past `maxSeconds`
    ///     is a real turn whatever the words.
    public static func isBackchannel(_ text: String, seconds: Double, maxSeconds: Double = 1.2) -> Bool {
        guard seconds <= maxSeconds else { return false }
        let norm = normalise(text)
        // Empty after normalising means punctuation or noise, not "mm-hmm";
        // a real turn in any language keeps its letters (`normalise` is
        // Unicode-aware), and an empty transcript is handled before this.
        guard !norm.isEmpty else { return false }
        if backchannels.contains(norm) { return true }
        // Two backchannels in a row ("yeah okay") are still a backchannel.
        let words = norm.split(separator: " ").map(String.init)
        return words.count <= 2 && words.allSatisfy { backchannels.contains($0) }
    }

    // MARK: - Words, not sound

    /// Sounds a recogniser writes down that are not anybody taking the floor:
    /// hesitation noises, and the shapes it makes out of a cough or a chair.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "eh", "ah", "ahh", "oh", "hm", "hmm", "hmmm",
        "mm", "mmm", "mhm", "huh",
    ]

    /// The normalised words of a transcript, in order.
    public static func words(_ text: String) -> [String] {
        normalise(text).split(separator: " ").map(String.init)
    }

    /// How many words that could be somebody taking the floor the streaming
    /// recogniser has written *after* the first `baseline` words of `text`.
    ///
    /// This is the gate between "the VAD heard something speech-shaped" and
    /// "somebody is talking". Measured on the owner's log (2026-08-28 →
    /// 09-07): 148 VAD onsets while Moe was thinking took the floor and 83 of
    /// them came back with no words at all — a fan, a dish, a cough — and
    /// every one of those held the reply for two to twenty-five seconds.
    /// Every serious voice stack gates on words now (Deepgram Flux,
    /// LiveKit's `min_interruption_words`, Pipecat's min-words strategy).
    ///
    /// What does not count: hesitation noises ("um", "hmm"), single letters
    /// (what noise decodes to), and a lone backchannel ("yeah", "okay"),
    /// which is said *to* a speaker rather than *as* one. Any script counts —
    /// `normalise` keeps every letter, so Hebrew or Russian words are words
    /// (stripping them to nothing is a bug this file has already had once).
    ///
    /// - Parameter countNods: count "yes", "okay", "sure" too. True wherever
    ///   the person has the floor — there a lone "yes" is an answer, and the
    ///   filler list alone ("uh", "um", "hm", single letters) is what is not
    ///   a word. False only over Moe's own voice, where it is a nod.
    ///   "no" and "stop" are never nods (`VoiceMachine.wordsCountNods`).
    public static func meaningfulWords(in text: String, after baseline: Int = 0,
                                       countNods: Bool = false) -> Int {
        let all = words(text)
        let from = max(0, baseline)
        guard all.count > from else { return 0 }
        let fresh = all[from...].filter { word in
            if fillers.contains(word) { return false }
            if word.count >= 2 { return true }
            return word.allSatisfy(\.isNumber)
        }
        guard !fresh.isEmpty else { return 0 }
        // "yeah", "okay", "yeah okay": a nod, not a turn.
        if !countNods, fresh.count <= 2, fresh.allSatisfy({ backchannels.contains($0) }) { return 0 }
        return fresh.count
    }

    /// Words that stop a speaker on their own: one of these is enough to
    /// take the floor over Moe's voice, where anything else needs two words
    /// (`VoiceMachine.Tuning.interruptionWordsWhileSpeaking`). The list is
    /// research-interruptions.md §5's ("stop", "wait", "no", "hold on",
    /// "Moe"), and the recogniser's spellings of the name.
    public static let stopWords: Set<String> = [
        "stop", "wait", "no", "nope", "hold", "hang", "pause", "enough", "quiet", "shush", "shh",
        "cancel", "moe", "mo",
    ]

    /// Among the words after `baseline`, is there one that stops a speaker
    /// by itself?
    public static func hasStopWord(in text: String, after baseline: Int = 0) -> Bool {
        let all = words(text)
        guard all.count > max(0, baseline) else { return false }
        return all[max(0, baseline)...].contains { stopWords.contains($0) }
    }

    // MARK: - Completeness

    /// Words a person trails off on when there is more coming.
    static let danglers: Set<String> = [
        "and", "but", "or", "so", "because", "cause", "if", "then", "the", "a", "an",
        "to", "of", "with", "for", "in", "on", "at", "by", "from", "that", "which",
        "um", "uh", "er", "erm", "like", "you know", "i mean", "actually", "basically",
        "is", "are", "was", "were", "it's", "its", "my", "your", "their", "his", "her",
        "very", "really", "not", "also", "about", "into", "than", "as", "when", "while",
        // Pointing forward: "go to those", "open these". Measured 2026-09-07,
        // a request cut after "those" at p=0.96.
        "these", "those",
        // Spoken "want to"/"going to": always followed by the verb.
        "wanna", "gonna", "gotta", "wanted", "want", "need", "trying",
    ]

    /// Does the transcript read as a finished thought?
    ///
    /// Terminal punctuation says yes. A trailing filler or conjunction says
    /// no. Anything else is unknown, and the caller falls back to its
    /// audio signals.
    public enum Completeness: Equatable, Sendable { case complete, incomplete, unknown }

    public static func completeness(of text: String) -> Completeness {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        if let last = trimmed.last, ".!?".contains(last) { return .complete }
        let norm = normalise(trimmed)
        let words = norm.split(separator: " ").map(String.init)
        guard let last = words.last else { return .unknown }
        if danglers.contains(last) { return .incomplete }
        if words.count >= 2, danglers.contains(words.suffix(2).joined(separator: " ")) { return .incomplete }
        return .unknown
    }

    // MARK: - The silence budget

    /// How long to wait after the person stops, given what they have said
    /// so far. The endpointer and the turn model can end a turn earlier;
    /// this is the ceiling.
    ///
    /// - Parameters:
    ///   - base: the wait for an unknown shape.
    ///   - completeFactor: the fraction of `base` after a finished thought.
    ///   - incompleteFactor: the multiple of `base` after a dangling one.
    public static func silenceBudget(for text: String, base: Double = 1.0,
                                     completeFactor: Double = 0.5, incompleteFactor: Double = 2.0,
                                     cap: Double = 3.0) -> Double {
        switch completeness(of: text) {
        case .complete: return max(0.2, base * completeFactor)
        case .incomplete: return min(cap, base * incompleteFactor)
        case .unknown: return min(cap, base)
        }
    }

    // MARK: - Helpers

    static func normalise(_ s: String) -> String {
        var out = s.lowercased()
        // Apple's recogniser writes ’; "that’s" must stay one word.
        out = out.replacingOccurrences(of: "’", with: "'")
        // Every script, not only Latin: this feeds the word counts and the
        // lexical rules, and stripping Hebrew or Russian to nothing made
        // every follow-up in those languages look like an empty turn.
        out = out.replacingOccurrences(of: "[^\\p{L}\\p{N}' -]", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Which transcript a turn goes with: the accurate re-read's, or the live
/// recogniser's words that were on the island while the person spoke.
///
/// The re-read wins whenever it *ran*, including when it ran and heard
/// nothing — an empty answer from the model that looked hardest is an
/// answer, and it is what stops silence, a door, or the tail of an
/// abandoned utterance from reaching the brain as a sentence.
///
/// The case this type exists for is the one that is **not** an answer: the
/// re-read never came back at all. On 2026-09-09 those two were the same
/// empty string, so a timed-out read overruled a minute of correctly heard
/// dictation and the turn was dropped with nothing anywhere to say why.
/// `TurnReadDeadline` is why the read timed out; this is why that had to
/// cost the whole turn, and it did not have to.
public enum ReadOutcome: Equatable, Sendable {
    /// The engine answered. Its text stands, empty or not.
    case answered(String)
    /// The deadline won; the engine never answered.
    case neverAnswered
}

extension TurnPolicy {

    /// The words the turn submits.
    ///
    /// - Parameters:
    ///   - read: what the accurate re-read produced, if anything.
    ///   - live: what the live recogniser had written down by the time the
    ///     turn was taken — the text the person watched appear.
    public static func transcript(read: ReadOutcome, live: String) -> String {
        switch read {
        case .answered(let text): return text
        case .neverAnswered: return live
        }
    }

    /// True when the turn is standing on the live recogniser's words
    /// because the re-read never came back. Worth a log line: it is the
    /// only signal that the accurate path is failing while turns keep
    /// working.
    public static func fellBackToLiveWords(read: ReadOutcome, live: String) -> Bool {
        read == .neverAnswered && !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
