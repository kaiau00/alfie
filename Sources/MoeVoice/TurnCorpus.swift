import Foundation

/// The noisy conversation corpus `Moe --turn-bench --corpus` reads: the
/// manifest `scripts/turnbench/mix.py` writes next to its WAVs
/// (research-eval-harness.md §3.5–3.6, §4). Pure data; the bench records a
/// `TurnTape` per scenario and `CorpusScore` scores it against the truth here.
///
/// Two kinds of scenario:
/// - **turn**: Moe is listening and the person says one line. The truth is
///   every word's time, the pauses they went on after, and the true end.
/// - **reply**: Moe is talking, and the person says a stop word, a real
///   interruption, a backchannel — or nothing (`interjection == nil`), for
///   the false barge-in rate. The reply's own words are the playhead the
///   echo check reads, and its audio is in the mix as the canceller's residue.
public struct TurnCorpus: Codable, Sendable {

    public struct Word: Codable, Equatable, Sendable {
        public var word: String
        public var start: Double
        public var end: Double
        /// The last word of a sentence (a reply's words only): where one
        /// piece of speech hands over to the next.
        public var sentenceEnd: Bool?
        public init(_ word: String, _ start: Double, _ end: Double, sentenceEnd: Bool? = nil) {
            self.word = word; self.start = start; self.end = end; self.sentenceEnd = sentenceEnd
        }
    }

    public struct Reply: Codable, Equatable, Sendable {
        /// When Moe's reply is audible, in file time.
        public var start: Double
        public var end: Double
        public var voice: String?
        public var words: [Word]
        public init(start: Double, end: Double, voice: String? = nil, words: [Word]) {
            self.start = start; self.end = end; self.voice = voice; self.words = words
        }
    }

    public struct Interjection: Codable, Equatable, Sendable {
        /// `stop`, `interrupt` or `backchannel`.
        public var kind: String
        public var text: String
        /// First word's start and last word's end, in file time.
        public var start: Double
        public var end: Double
        public init(kind: String, text: String, start: Double, end: Double) {
            self.kind = kind; self.text = text; self.start = start; self.end = end
        }
        /// Something Moe must stop for: a stop word or a real new request.
        /// A backchannel is not.
        public var isReal: Bool { kind == "stop" || kind == "interrupt" }
    }

    public struct Scenario: Codable, Equatable, Sendable {
        public var id: String
        /// The scenario before mixing: its copies at each SNR share it.
        public var base: String
        public var wav: String
        /// `turn` or `reply`.
        public var kind: String
        /// single, pause, filler, and, correction, short / stop, interrupt, backchannel, none.
        public var category: String
        public var split: String
        public var voice: String
        /// Signal-to-noise ratio in dB over the person's speech; nil = clean.
        public var snr: Double?
        public var noise: String?
        public var rir: Bool?
        /// The simulated echo's level against the person's speech, dB; nil = none.
        public var echoDb: Double?
        /// The person's speech level as a session would have opened on it —
        /// what the engine's loudness check divides by.
        public var referenceRms: Double?
        public var duration: Double
        public var words: [Word]
        // turn
        public var holds: [TurnTape.Span]?
        public var end: TurnTape.Span?
        public var text: String?
        // reply
        public var reply: Reply?
        public var interjection: Interjection?

        public init(id: String, base: String? = nil, wav: String = "", kind: String, category: String,
                    split: String = "test", voice: String = "v", snr: Double? = nil, echoDb: Double? = nil,
                    referenceRms: Double? = nil, duration: Double, words: [Word] = [],
                    holds: [TurnTape.Span]? = nil, end: TurnTape.Span? = nil, text: String? = nil,
                    reply: Reply? = nil, interjection: Interjection? = nil) {
            self.id = id; self.base = base ?? id; self.wav = wav; self.kind = kind; self.category = category
            self.split = split; self.voice = voice; self.snr = snr; self.echoDb = echoDb
            self.referenceRms = referenceRms; self.duration = duration; self.words = words
            self.holds = holds; self.end = end; self.text = text; self.reply = reply
            self.interjection = interjection
        }

        public var isTurn: Bool { kind == "turn" }
        public var isReply: Bool { kind == "reply" }

        /// The truth `EotScore` reads, for a turn.
        public var truth: TurnTape.Truth? {
            guard isTurn, let end else { return nil }
            return TurnTape.Truth(holds: holds ?? [], end: end)
        }

        /// "clean", "20", "10"… — the SNR as the tables print it.
        public var snrLabel: String { snr.map { String(format: "%.0f", $0) } ?? "clean" }
        public var echoLabel: String { echoDb.map { String(format: "%.0f", $0) } ?? "none" }
    }

    public var version: Int
    public var sampleRate: Int
    public var split: String?
    public var scenarios: [Scenario]

    public init(version: Int = 1, sampleRate: Int = 16_000, split: String? = nil, scenarios: [Scenario]) {
        self.version = version; self.sampleRate = sampleRate; self.split = split; self.scenarios = scenarios
    }
}
