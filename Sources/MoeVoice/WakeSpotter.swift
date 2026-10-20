import Foundation

/// Finds the wake phrase in a streaming transcript.
///
/// Phase 1 of VOICE-PLAN.md §4.1: still a match on the recogniser's text,
/// but honest about it — whole words only, the phrase as the *last* thing
/// said (the tail, because the recogniser hands back everything it has
/// heard since the last reset), and never a fragment like "hey mo" that
/// fires inside ordinary speech. Phase 4 replaces this with a trained
/// wake-word model; the host's contract (`.woke`) does not change.
public struct WakeSpotter: Sendable {

    public let phrases: [String]

    /// - Parameter phrases: accepted spellings, lowercase. Empty ones and
    ///   anything shorter than two words are dropped — one word is not a
    ///   wake phrase, it is a false accept waiting to happen.
    public init(phrases: [String]) {
        self.phrases = phrases
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.split(separator: " ").count >= 2 || $0.count >= 5 }
    }

    /// The default phrase plus the misreadings the recogniser produces
    /// for it.
    public static let defaultPhrases = ["hey moe", "hey mo", "heymo", "hey mow", "hey moore"]

    public struct Match: Equatable, Sendable {
        /// Character offset just past the phrase in the text it was found in.
        public let end: Int
        /// What came after the phrase, cleaned — usually the request.
        public let tail: String
    }

    /// The most recent wake phrase in the last `window` characters, if it is
    /// the last thing said or is followed by at most a request.
    ///
    /// "okay dude, hey Moe is a weird name" must not fire: the phrase has to
    /// be followed by nothing, or by text that starts after it (which is the
    /// request). Anything *before* it in the window is history and ignored.
    public func match(in text: String, window: Int = 90) -> Match? {
        let lower = text.lowercased()
        let chars = Array(lower)
        let start = max(0, chars.count - window)
        var best: Int?
        for phrase in phrases {
            let p = Array(phrase)
            guard !p.isEmpty, p.count <= chars.count else { continue }
            var i = start
            while i + p.count <= chars.count {
                if Array(chars[i..<(i + p.count)]) == p {
                    let beforeOK = i == 0 || !chars[i - 1].isLetter
                    let after = i + p.count
                    let afterOK = after == chars.count || !chars[after].isLetter
                    if beforeOK, afterOK, best.map({ after > $0 }) ?? true { best = after }
                    i = after
                } else {
                    i += 1
                }
            }
        }
        guard let end = best else { return nil }
        let tail = String(Array(text)[end...])
        return Match(end: end, tail: Self.clean(tail))
    }

    /// Strip a leading wake phrase from an accurate transcript, which reads
    /// the whole utterance, name included. `anywhere`: a wake turn's
    /// capture carries pre-roll from before the name ("…see you later.
    /// Hey Moe, what's the weather"); keep only what follows the last
    /// match, since the head fired on it.
    public func strippingPhrase(from text: String, anywhere: Bool = false) -> String {
        if anywhere, let hit = match(in: text, window: Int.max) { return hit.tail }
        // The head heard the name; the recogniser often did not. Two words
        // of "Hey Moe" come back as "Hey man", "Hey Mo.", "hemo", "Amo" —
        // and a turn that starts with what the head just fired on is the
        // name, not the request. Only on a wake turn, only at the front,
        // and only for something that could be it.
        if anywhere, let stripped = Self.strippingMisheardName(text) { return Self.clean(stripped) }
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = out.lowercased()
        for phrase in phrases where lower.hasPrefix(phrase) {
            let after = out.index(out.startIndex, offsetBy: phrase.count)
            // Whole word: "hey moe" but not "hey moebius".
            if after == out.endIndex || !out[after].isLetter {
                out = String(out[after...])
                break
            }
        }
        return Self.clean(out)
    }

    /// A leading greeting-plus-short-M-word, or a short M-word alone: what
    /// "Hey Moe" becomes when the recogniser guesses. Nil when the start of
    /// the turn does not look like the name at all, so a real request is
    /// never eaten.
    static func strippingMisheardName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard let first = words.first else { return nil }
        let greetings: Set<String> = ["hey", "hi", "hay", "a", "hey,", "hi,", "ok", "okay"]
        func looksLikeMoe(_ w: Substring) -> Bool {
            let word = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
            guard word.count <= 5, word.first == "m" else { return false }
            // "my", "me", "more" and "make" start requests; the name does not.
            return !["my", "me", "more", "make", "made", "most", "much", "must", "may"].contains(word)
        }
        // "Hey Mo, what's the weather" → "what's the weather"
        if greetings.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))),
           words.count >= 2, looksLikeMoe(words[1]) {
            return words.count > 2 ? String(words[2]) : ""
        }
        // "Hemo, what time is it" → "what time is it": the greeting and the
        // name run together into one word.
        func gluedName(_ w: Substring) -> Bool {
            let word = w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
            guard word.count <= 6 else { return false }
            for greeting in ["hey", "hay", "hi", "he", "a"] where word.hasPrefix(greeting) {
                let rest = word.dropFirst(greeting.count)
                if rest.first == "m", rest.count <= 3 { return true }
            }
            return false
        }
        if gluedName(first) {
            return words.count > 1 ? words.dropFirst().joined(separator: " ") : ""
        }
        if looksLikeMoe(first), first.count >= 3 {
            return words.count > 1 ? words.dropFirst().joined(separator: " ") : ""
        }
        // The name heard as a different word altogether. 2026-09-29 20:40:
        // "Hey Moe, what happened to our subagents?" reached the brain as
        // "Emma? What happened…", and Moe answered "I'm Moe, not Emma" —
        // twice. Only on a wake turn, and only as the first word, which is
        // where the head just heard the name.
        let bare = first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
        if Self.nameMishearings.contains(bare) {
            return words.count > 1 ? words.dropFirst().joined(separator: " ") : ""
        }
        // A greeting on its own in front of the request — "Hey, what's on
        // today" — is the first half of the name with the second half lost:
        // five times from 09-24 to 09-29. The request is what follows it.
        if ["hey", "hey,", "hi,", "hay,"].contains(first.lowercased()), words.count >= 2,
           first.hasSuffix(",") || words.count > 2 {
            return words.dropFirst().joined(separator: " ")
        }
        return nil
    }

    /// Whole words the recogniser has written for "Moe" (or "Hey Moe") that
    /// do not start with an m, so `looksLikeMoe` cannot see them.
    static let nameMishearings: Set<String> = ["emma", "emo", "imo", "ammo", "amo", "elmo", "hemo", "himo"]

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;: "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
