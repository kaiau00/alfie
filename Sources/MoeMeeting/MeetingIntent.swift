import Foundation

/// The spoken commands Moe handles itself, before anything reaches the
/// brain: starting and stopping a meeting, and — during one — "what did
/// they just say", answered from the live transcript with no round-trip.
///
/// This was a list of seven exact phrases, and the phrase list was the bug:
/// "begin taking notes" is the same request as "start a meeting" and got
/// told to go and say the magic words instead. What replaces it is not a
/// classifier — recording other people must never start on a guess — but a
/// **closed vocabulary**: an utterance matches only when every one of its
/// words is a verb, an object or a filler this file names, and it carries
/// at least one starting verb and one thing to record. That is what keeps
/// "start a meeting with Dan tomorrow", "did you start the meeting" and
/// "don't start a meeting" out — `with`, `dan`, `tomorrow`, `did`, `you`,
/// `don`, `t` are in no set, so the whole utterance is refused. Every
/// unknown word is a refusal, which is the safe direction to fail in.
///
/// Anything that is not one of these goes to the brain as usual — and the
/// brain has its own way in now (`MeetingIntent.Marker`), so a phrasing
/// this grammar does not cover still starts a meeting rather than being
/// answered with an instruction to rephrase.
public enum MeetingIntent: Equatable, Sendable {
    case start
    case stop
    /// "What did they just say?" — the last thing the other side said,
    /// repeated on screen. Only meaningful while a meeting is recorded;
    /// the caller lets it through to the brain otherwise.
    case repeatLast

    /// Words that mean "begin". `record` is here and `recording` is not:
    /// the noun belongs to the objects below, so "stop recording" reads as
    /// a stopping verb and an object rather than as both directions at once.
    ///
    /// `turn` is deliberately absent. With `off` allowed as a filler (for
    /// "kick off the meeting") it would have read "turn off recording" as a
    /// start — the one direction this file must never get backwards. Left
    /// out, that utterance is simply unknown and goes to the brain, which
    /// can ask for the stop by marker.
    static let startVerbs: Set<String> = [
        "start", "starts", "begin", "begins", "record", "records",
        "capture", "transcribe", "take", "taking", "kick", "fire",
        "launch",
    ]

    static let stopVerbs: Set<String> = [
        "stop", "stops", "end", "ends", "finish", "finishing",
        "wrap", "quit", "halt", "cease", "close",
    ]

    /// The thing being recorded. One of these has to be named: a bare
    /// "start" is not a meeting, and never was.
    static let objects: Set<String> = [
        "meeting", "meetings", "call", "notes", "note", "minutes",
        "transcript", "transcription", "transcribing", "recording",
        "recordings", "session",
    ]

    /// Words that carry no intent either way and are allowed to appear.
    /// Kept deliberately short: every word added here is a word that can
    /// no longer refuse an utterance, and the refusals are the safety.
    static let fillers: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "our",
        "it", "its", "up", "off", "on", "down", "for", "of", "to", "and",
        "making", "keeping", "writing", "going", "please", "now", "here",
        "some", "all", "everything",
    ]

    static let repeatPhrases: Set<String> = [
        "what did they just say",
        "what did they say",
        "what did he just say",
        "what did he say",
        "what did she just say",
        "what did she say",
        "what was that",
        "what did i miss",
        "repeat that",
        "say that again",
        "what did they just say again",
    ]

    /// The intent an utterance is, or nil when it is anything else.
    public static func match(_ utterance: String) -> MeetingIntent? {
        let key = fold(utterance)
        guard !key.isEmpty else { return nil }
        if repeatPhrases.contains(key) { return .repeatLast }

        let words = key.split(separator: " ").map(String.init)
        // One unknown word and the whole utterance goes to the brain. This
        // is the guard: negations, questions, names, times and second
        // clauses all arrive as words no set below contains.
        guard words.allSatisfy({
            startVerbs.contains($0) || stopVerbs.contains($0)
                || objects.contains($0) || fillers.contains($0)
        }) else { return nil }
        guard words.contains(where: objects.contains) else { return nil }

        // The first verb decides, because that is how the sentence reads:
        // "stop taking notes" carries a stopping verb and a starting one,
        // and it plainly means stop. Refusing anything with both would
        // have refused the commonest way of asking for it.
        for word in words {
            if stopVerbs.contains(word) { return .stop }
            if startVerbs.contains(word) { return .start }
        }
        return nil
    }

    /// Lowercased, punctuation gone, one space between words; leading
    /// address and politeness ("hey Moe", "could you", "I want to") and
    /// trailing politeness are stripped, so "Hey Moe, could you please
    /// start taking notes now" folds to "start taking notes".
    ///
    /// The strip repeats until nothing more comes off: it used to make one
    /// pass in a fixed order, so "can you please start" kept the "please"
    /// that sat behind the "can you" the pass had already gone past.
    static func fold(_ s: String) -> String {
        let letters = s.lowercased().unicodeScalars.map { u -> Character in
            CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) ? Character(u) : " "
        }
        var words = String(letters).split(separator: " ").map(String.init)
        let prefixes: [[String]] = [
            ["hey", "alfie"], ["hey", "alfy"], ["alfie"], ["alfy"], ["please"],
            ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
            ["i", "want", "to"], ["i", "d", "like", "to"], ["i", "would", "like", "to"],
            ["go", "ahead", "and"], ["just"], ["ok"], ["okay"], ["alright"],
            ["sorry"], ["let", "s"], ["lets"],
        ]
        var strippedSomething = true
        while strippedSomething {
            strippedSomething = false
            for prefix in prefixes where words.count > prefix.count {
                if Array(words.prefix(prefix.count)) == prefix {
                    words.removeFirst(prefix.count)
                    strippedSomething = true
                }
            }
        }
        while let last = words.last, ["please", "now", "thanks", "ok", "okay"].contains(last), words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}

extension MeetingIntent {

    /// What the brain writes when it has been asked to record and the
    /// grammar above did not catch the wording.
    ///
    /// Its own token, never the user's words, exactly as the goodbye marker
    /// works (`Conductor.endMarker`): reading it is not phrase matching, it
    /// survives any language, and it cannot be produced by a page Moe read
    /// or a file it opened, because only the model's own reply is scanned.
    /// Moe still owns what happens next — the consent sheet, the ring, the
    /// recorder — so this is a request to Moe, not the model recording.
    public enum Marker: String, CaseIterable, Sendable {
        case start = "<meeting:start/>"
        case stop = "<meeting:stop/>"

        public var intent: MeetingIntent { self == .start ? .start : .stop }
    }

    /// The marker in a finished reply, or nil. `.start` wins if a confused
    /// reply somehow carries both: an explicit stop with no meeting running
    /// is a no-op, whereas starting one that was asked for is the request.
    public static func marker(in reply: String) -> Marker? {
        if reply.contains(Marker.start.rawValue) { return .start }
        if reply.contains(Marker.stop.rawValue) { return .stop }
        return nil
    }

    /// The reply with the markers taken out — for the transcript and for
    /// the voice, neither of which should ever carry them.
    public static func strippingMarkers(_ reply: String) -> String {
        var out = reply
        for marker in Marker.allCases {
            out = out.replacingOccurrences(of: marker.rawValue, with: "")
        }
        return out
    }
}
