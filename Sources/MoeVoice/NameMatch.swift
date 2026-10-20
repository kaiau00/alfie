import Foundation

/// Does this transcript name Moe? One matcher for every place that lets the
/// name through — the barge-in judge, the owner gate — because each had its
/// own and each missed spellings the others knew (review M4): "Mo, stop",
/// "Moe's", the owner's own "Hey Moe" written as "Hey Moon", "hemo".
public enum NameMatch {

    /// The name anywhere, as the recogniser writes it. Whole tokens only:
    /// "chemo", "Alamo", "more", "moment" are not the name.
    static let anywhere: Set<String> = ["moe", "mo", "moe's", "moes", "mo's"]
    /// Words that are the name only at the start of what was said (or after
    /// a greeting): "Moon, stop" is the name; "the moon", "mow the lawn" are not.
    static let atTheStart: Set<String> = ["moon", "mow", "mau", "moo"]
    /// "Hey Moe" run together, as the recogniser writes it.
    static let glued: Set<String> = ["hemo", "heymo", "heymoe", "hamo", "amo"]
    static let greetings: Set<String> = ["hey", "hi", "hay", "ok", "okay", "oh"]

    /// A token that is the name wherever it stands.
    public static func nameToken(_ w: String) -> Bool { anywhere.contains(w) || glued.contains(w) }

    /// - Parameter spotter: the configured wake phrases, which count too.
    public static func namesMoe(_ text: String, spotter: WakeSpotter? = nil) -> Bool {
        let words = TurnPolicy.words(text)
        guard !words.isEmpty else { return false }
        if words.contains(where: nameToken) { return true }
        var first = 0
        while first < words.count - 1, greetings.contains(words[first]) { first += 1 }
        if atTheStart.contains(words[first]) { return true }
        if let spotter, spotter.match(in: text, window: Int.max) != nil { return true }
        return false
    }
}

/// What the host tells the machine about the words so far — the rule
/// `VoiceEngine.reportWords` and the replay share. A word that stops a
/// speaker can arrive by the recogniser *revising* a word ("know" → "no")
/// with no rise in the count, and must still be reported (review M2).
public struct WordReport: Equatable, Sendable {
    public private(set) var count = 0
    public private(set) var urgent = false
    public init() {}

    /// The event to send for this partial, if any.
    public mutating func update(text: String, baseline: Int, countNods: Bool) -> (words: Int, urgent: Bool)? {
        let n = TurnPolicy.meaningfulWords(in: text, after: baseline, countNods: countNods)
        let u = TurnPolicy.hasStopWord(in: text, after: baseline)
        // Not sticky: "no" that the recogniser goes on to write as "nothing",
        // or "mo" as "moment", was never a stop word (review N2).
        let wasUrgent = urgent
        urgent = u
        if n > count || (u && !wasUrgent && n > 0) {
            count = max(count, n)
            return (count, urgent)
        }
        return nil
    }

    public mutating func reset() { count = 0; urgent = false }
}
