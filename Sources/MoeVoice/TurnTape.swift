import Foundation

/// What the host saw during one stretch of somebody talking, on a clock:
/// the VAD's edges, the streaming recogniser's partials and end-of-utterance
/// tokens, and what Smart Turn would have answered if asked at a given
/// moment. `PolicyReplay` drives `VoiceMachine` from it in virtual time, so
/// a threshold can be swept over hundreds of turns in a second.
///
/// A tape is recorded, never invented by the replay: `Moe --turn-bench`
/// makes one per file by running it through the real pipeline (Silero,
/// the noise-floor gate, Parakeet's streaming recogniser, Smart Turn),
/// and a test can write one by hand for an incident with a known answer.
/// research-eval-harness.md §3.2 is the design.
public struct TurnTape: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case speechStarted, speechEnded, partial, endOfUtterance
        /// `NoiseFloorGate.Edge.rose`: already in speech, and louder.
        case speechRose
    }

    public struct Event: Codable, Equatable, Sendable {
        /// Seconds from the start of the tape.
        public var t: Double
        public var kind: Kind
        /// The recogniser's whole transcript so far (`partial`) or its
        /// utterance (`endOfUtterance`).
        public var text: String?
        public init(t: Double, _ kind: Kind, _ text: String? = nil) {
            self.t = t; self.kind = kind; self.text = text
        }
    }

    /// Smart Turn's probability for the audio as the host would have handed
    /// it over at `t` — trimmed the way `VoiceEngine.askTurnModel` trims it.
    public struct Probe: Codable, Equatable, Sendable {
        public var t: Double
        public var p: Double
        public init(t: Double, p: Double) { self.t = t; self.p = p }
    }

    /// Where the person really paused and really stopped, when known
    /// (a corpus with word timings). The replay does not read it; the
    /// scorer does.
    public struct Span: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var duration: Double { end - start }
    }

    public struct Truth: Codable, Equatable, Sendable {
        /// Pauses the person went on after.
        public var holds: [Span]
        /// The pause that was the end of the turn.
        public var end: Span
        public init(holds: [Span], end: Span) { self.holds = holds; self.end = end }
    }

    public var id: String
    public var events: [Event]
    /// Probes by the tail of pause they were computed with ("0.30", "0.50", …).
    public var probes: [String: [Probe]]
    public var truth: Truth?
    /// How long the tape runs, lead-in and tail included.
    public var duration: Double

    public init(id: String, events: [Event], probes: [String: [Probe]] = [:],
                truth: Truth? = nil, duration: Double) {
        self.id = id
        self.events = events.sorted { $0.t < $1.t }
        self.probes = probes
        self.truth = truth
        self.duration = duration
    }

    /// The probe set key for a tail of `seconds`.
    public static func key(tail seconds: Double) -> String { String(format: "%.2f", seconds) }

    /// Smart Turn's answer at `t`: the latest probe at or before it. Nil
    /// when there is none (the model would not have been asked on audio it
    /// had not yet heard).
    public func probe(at t: Double, set key: String) -> Double? {
        guard let list = probes[key], !list.isEmpty else { return nil }
        var best: Probe?
        for p in list where p.t <= t + 1e-9 {
            if best == nil || p.t >= best!.t { best = p }
        }
        return best?.p
    }
}
