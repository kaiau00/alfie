import Foundation

/// One barge-in decision — a voice over Moe let through or let go — and
/// which check decided it, with the numbers that check read.
///
/// Every onset over a reply (or over Moe thinking, or over the first half
/// being read back) ends in exactly one of these. Before 2026-09-23 only
/// the judge's half left a log line, and "why did it stop?" had no answer
/// in the trace; these rows are also the training set for a learned judge
/// (research-interruptions.md §4 Stage A), so they carry the signals, never
/// the words.
public struct BargeInDecision: Codable, Equatable, Sendable {

    public enum Check: String, Codable, Sendable {
        /// The word window: the recogniser wrote enough words, or none.
        case words
        /// Loudness against the voice that opened the session.
        case loudness
        /// The speaker embedding against the owner's enrolment.
        case ownerVoice = "owner-voice"
        /// The words match what Moe is saying right now: its own echo.
        case echoText = "echo-text"
        /// Nothing could be measured (no reference, too little audio); the
        /// voice is let through, because a barge-in that never fires is
        /// worse than one that fires too often.
        case noSignal = "no-signal"
        /// Over Moe thinking or the first half being read back: words are
        /// the whole test there (nothing is playing to be paused).
        case continuation
        /// The onset was overtaken — a key, the name, a dictation, the
        /// reply finishing — before anything was decided.
        case superseded
        /// Taken, then the accurate read of the whole of it found no words.
        case readEmpty = "read-empty"
        /// Taken, then read as "mm-hmm", "yeah": said to a speaker.
        case backchannel
        /// Taken, then judged said to somebody else (`Addressee`).
        case addressee
    }

    /// Where the onset landed: "speaking", "thinking", "deciding".
    public var window: String
    public var taken: Bool
    public var check: Check
    public var words: Int?
    /// Speech level against the session's opening voice.
    public var levelRatio: Double?
    /// Cosine against the owner's enrolment.
    public var ownerScore: Double?
    /// Similarity of the words to the sentence Moe is saying now.
    public var echoSimilarity: Double?
    /// The owner score would have refused this voice, but the owner check is
    /// not enforcing (`ownerGateEnforce`), so it did not (review N4).
    public var ownerWouldRefuse: Bool?

    public init(window: String, taken: Bool, check: Check, words: Int? = nil,
                levelRatio: Double? = nil, ownerScore: Double? = nil, echoSimilarity: Double? = nil) {
        self.window = window
        self.taken = taken
        self.check = check
        self.words = words
        self.levelRatio = levelRatio
        self.ownerScore = ownerScore
        self.echoSimilarity = echoSimilarity
    }

    /// `barge-in over speaking: taken by loudness (words 2, level 0.91)`.
    public var logLine: String {
        var bits: [String] = []
        if let words { bits.append("words \(words)") }
        if let levelRatio { bits.append(String(format: "level %.2f", levelRatio)) }
        if let ownerScore { bits.append(String(format: "owner %.2f", ownerScore)) }
        if let echoSimilarity { bits.append(String(format: "echo %.2f", echoSimilarity)) }
        let detail = bits.isEmpty ? "" : " (" + bits.joined(separator: ", ") + ")"
        return "barge-in over \(window): \(taken ? "taken" : "refused") by \(check.rawValue)\(detail)"
    }

    /// Onto a trace row.
    public func stamp(_ t: inout TurnTrace) {
        t.bargeInTaken = taken
        t.bargeInCheck = check.rawValue
        t.bargeInLevel = levelRatio.map { ($0 * 1000).rounded() / 1000 }
        t.bargeInOwner = ownerScore.map { ($0 * 1000).rounded() / 1000 }
        t.bargeInEcho = echoSimilarity.map { ($0 * 1000).rounded() / 1000 }
        if t.onsetWords == nil { t.onsetWords = words }
    }
}

/// Whose voice is talking over the reply — the host's side of
/// `VoiceMachine.Action.judgeBargeIn`, as a rule so it is a test.
public enum BargeInJudge {

    /// Quieter than this against the voice that opened the session is
    /// somebody further away: talking near the person, not to Moe.
    public static let loudnessRefuseBelow = 0.35

    /// Everything cheap that can say whose voice it is, measured *before*
    /// the reply is paused (research-interruptions.md §0 #1). Until
    /// 2026-09-23 only loudness ran here; the owner score and the echo match
    /// ran after the capture ended, so a false stop was audible first and
    /// "resumed" afterwards.
    public struct Signals: Equatable, Sendable {
        public var window: String
        public var words: Int
        /// The words name Moe (`NameMatch.namesMoe`).
        public var named = false
        /// Among the words is one that stops a speaker by itself
        /// (`TurnPolicy.stopWords`).
        public var urgent = false
        /// Cosine of the person's own audio since the onset — pre-roll and
        /// Moe's residue before it excluded — against the owner's enrolment;
        /// nil with no enrolment.
        public var ownerScore: Double?
        /// How many seconds of the person's audio that score was taken on.
        public var ownerSeconds: Double = 0
        /// `EchoFilter.windowSimilarity` of the words against the sentence
        /// playing now.
        public var echoSimilarity: Double?
        /// The onset's words as heard, for the echo check's minimum.
        public var heard: String = ""
        /// Loudness against the session's opening voice.
        public var levelRatio: Double?
        /// The stop word or name that was heard is in the words Moe is
        /// saying right now (`BargeInJudge.echoesThePlayhead`): its own "no",
        /// "wait" or "Moe" coming back through the speakers (review N1).
        public var urgentEchoesPlayhead = false
        /// The owner score may refuse (`ownerGateEnforce`); otherwise it is
        /// written down and the words and level decide (review N4).
        public var enforceOwner = false
        public init(window: String, words: Int, named: Bool = false, urgent: Bool = false,
                    ownerScore: Double? = nil, ownerSeconds: Double = 0,
                    echoSimilarity: Double? = nil, heard: String = "", levelRatio: Double? = nil) {
            self.window = window; self.words = words; self.named = named; self.urgent = urgent
            self.ownerScore = ownerScore; self.ownerSeconds = ownerSeconds
            self.echoSimilarity = echoSimilarity; self.heard = heard; self.levelRatio = levelRatio
        }
    }

    /// Under this against the owner's enrolment, on at least
    /// `ownerMinSeconds` of the person's own audio, it is decisively not
    /// the owner: Moe's own voice scored 0.17, the owner 0.51–0.85 (17 whole
    /// turns, 2026-09-04). Those were whole turns; a second of audio at
    /// barge-in is noisier, and nobody has measured it — so only a score
    /// near Moe's own refuses here, and anything above falls through to the
    /// words and the level (review H2). The post-read check keeps 0.35.
    public static let ownerRefuseBelow = 0.2
    /// Less of the person's own audio than this, and the owner score says
    /// nothing either way.
    public static let ownerMinSeconds = 1.0
    /// Over this it is the owner, whatever the words look like.
    public static let ownerTakeAbove = 0.5
    /// The words are Moe's own sentence coming back. The post-read check's
    /// bar for a short transcript is 0.6 against the whole reply; against
    /// only the sentence playing now a stricter 0.8 keeps a real "stop"
    /// from matching a sentence that happens to hold similar letters.
    public static let echoRefuseAtOrAbove = 0.8
    /// …and only on this much of a match: a character-level similarity on
    /// one or two words finds "no" inside "know" and "mo" inside "more" at
    /// 1.0 (review H1). Three words, or twelve characters, before the echo
    /// check alone can refuse.
    public static let echoMinWords = 3
    public static let echoMinChars = 12

    /// Owner first (it separates the owner from Moe by 0.3 and from a
    /// stranger by most of that), then Moe's own words, then loudness. The
    /// name always gets through: a second person can join a conversation by
    /// asking for Moe, and the owner saying "Moe, stop" must never be
    /// refused on a noisy score.
    public static func decide(_ s: Signals) -> BargeInDecision {
        func d(_ taken: Bool, _ check: BargeInDecision.Check) -> BargeInDecision {
            BargeInDecision(window: s.window, taken: taken, check: check, words: s.words,
                            levelRatio: s.levelRatio, ownerScore: s.ownerScore, echoSimilarity: s.echoSimilarity)
        }
        // The exemptions first, before any score: the name, and a word that
        // stops a speaker ("no", "stop", "wait"). A missed "stop" is the worse
        // error — a false one pauses the reply and the read afterwards
        // resumes it; a refused one leaves the person shouting over Moe.
        //
        // Unless the word is one Moe is saying right now: its own "no",
        // "wait" or its own name coming back through the speakers would
        // otherwise pause the reply and spend its one pause (review N1).
        if s.named || s.urgent {
            return s.urgentEchoesPlayhead ? d(false, .echoText) : d(true, .words)
        }
        var shadowRefuse = false
        if let owner = s.ownerScore, s.ownerSeconds >= ownerMinSeconds {
            if owner < ownerRefuseBelow {
                if s.enforceOwner { return d(false, .ownerVoice) }
                shadowRefuse = true
            } else if owner >= ownerTakeAbove {
                return d(true, .ownerVoice)
            }
        }
        func dd(_ taken: Bool, _ check: BargeInDecision.Check) -> BargeInDecision {
            var out = d(taken, check)
            if shadowRefuse { out.ownerWouldRefuse = true }
            return out
        }
        let normalised = EchoFilter.normalise(s.heard)
        let enough = TurnPolicy.words(s.heard).count >= echoMinWords || normalised.count >= echoMinChars
        if enough, let echo = s.echoSimilarity, echo >= echoRefuseAtOrAbove { return dd(false, .echoText) }
        guard let level = s.levelRatio else { return dd(true, .noSignal) }
        return dd(level >= loudnessRefuseBelow, .loudness)
    }

    /// Is every stop word or name in `heard` among the words of `playing` —
    /// the sentence playing now and the last few words heard before it,
    /// which is as far back as the canceller's echo and the recogniser's lag
    /// reach?
    public static func echoesThePlayhead(heard: String, playing: String) -> Bool {
        let said = Set(TurnPolicy.words(playing))
        let urgent = TurnPolicy.words(heard).filter { TurnPolicy.stopWords.contains($0) || NameMatch.nameToken($0) }
        guard !urgent.isEmpty else { return false }
        return urgent.allSatisfy { said.contains($0) }
    }

    /// The person's own audio in an onset capture: the capture opens with
    /// `prerollSeconds` from before the onset — Moe's ducked reply, not
    /// them — so that is dropped before the voice is scored (review H2).
    public static func ownAudio(_ capture: [Float], prerollSeconds: Double, sampleRate: Int = 16_000) -> [Float] {
        Array(capture.dropFirst(Int(prerollSeconds * Double(sampleRate))))
    }

    /// The loudness check alone — what the judge was until 2026-09-23.
    /// - Parameter levelRatio: the tail's RMS over the session's opening
    ///   voice; nil when there is no reference or too little audio.
    public static func loudness(window: String, words: Int?, levelRatio: Double?) -> BargeInDecision {
        guard let levelRatio else {
            return BargeInDecision(window: window, taken: true, check: .noSignal, words: words)
        }
        return BargeInDecision(window: window, taken: levelRatio >= loudnessRefuseBelow,
                               check: .loudness, words: words, levelRatio: levelRatio)
    }
}
