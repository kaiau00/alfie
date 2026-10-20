import Foundation

/// The half-second of silence Inworld puts at the end of every generation,
/// taken off the end of a reply.
///
/// Measured on the 24 A/B renders in `~/moe-voice-notes/inworld-ab/`
/// (2026-09-23, six variants × four replies, 57 generations): every
/// generation ends with **432–558 ms** (median 485) after its last sample at
/// or above −45 dBFS, and the last 150 ms of a generation never peaks above
/// **−50.5 dBFS** (median −74.7). The speech itself decays through −45 dBFS
/// within ~10 ms of −40 dBFS, so the threshold sits on the edge of the words
/// and 5 dB above the loudest floor.
///
/// `SpeechOut.onIdle` — "done speaking", the start of the follow-up window,
/// the island's done — waits for the last buffer to play out, so that
/// silence made every reply end half a second late.
///
/// **Only the reply's last generation loses it.** Between two generations the
/// same silence is the pause between two sentences (480–570 ms measured,
/// against 250–600 ms for Inworld's own pauses inside a generation), and
/// cutting it to 120 ms would run them together. So each generation's tail
/// beyond `keepSeconds` is *held* (`HeldTail`), played in front of the next
/// generation when one follows, and dropped when none does.
public struct TrailingSilence {

    /// A sample at or above this is speech. −45 dBFS: see above.
    public static let thresholdDBFS: Float = -45
    /// What is kept after the last word: the decay, and a natural stop.
    public static let keepSeconds = 0.12

    private let threshold: Float
    private let keep: Int
    /// Quiet samples after the last loud one, not yet handed on. Released
    /// the moment a loud sample follows them, so a pause inside a generation
    /// is delayed by at most one frame and never lost.
    private var pendingQuiet: [Float] = []

    public init(sampleRate: Double,
                thresholdDBFS: Float = TrailingSilence.thresholdDBFS,
                keepSeconds: Double = TrailingSilence.keepSeconds) {
        threshold = pow(10, thresholdDBFS / 20)
        keep = max(0, Int(sampleRate * keepSeconds))
    }

    /// One frame in; what may be played now out. Everything up to and
    /// including the frame's last loud sample, preceded by any quiet held
    /// from earlier frames. Order is preserved exactly.
    public mutating func push(_ frame: [Float]) -> [Float] {
        guard let lastLoud = frame.lastIndex(where: { abs($0) >= threshold }) else {
            pendingQuiet.append(contentsOf: frame)
            return []
        }
        var out = pendingQuiet
        out.append(contentsOf: frame[...lastLoud])
        pendingQuiet = Array(frame[(lastLoud + 1)...])
        return out
    }

    /// The generation is over. `keep`: the first `keepSeconds` of the trailing
    /// quiet, to play now. `held`: the rest, which is silence the next
    /// generation may want as its sentence pause.
    public mutating func finish() -> (keep: [Float], held: [Float]) {
        let k = min(keep, pendingQuiet.count)
        let result = (Array(pendingQuiet[..<k]), Array(pendingQuiet[k...]))
        pendingQuiet = []
        return result
    }
}

/// The silence taken off the end of one generation, kept until it is known
/// whether another generation follows it in the same reply.
public struct HeldTail {
    public let samples: [Float]
    public let sampleRate: Double
    /// When the player will have played everything scheduled before the
    /// tail — the moment the held silence would have started.
    public let startsAt: Date

    public init(samples: [Float], sampleRate: Double, startsAt: Date) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startsAt = startsAt
    }

    /// What to play in front of the next generation so the pause between the
    /// two is what Inworld made it. While the player still has audio queued,
    /// all of it. Once it has run dry, the pause is already happening in real
    /// time, so only what is left of it — never a longer gap than untrimmed.
    public func remainder(now: Date, playerHasAudio: Bool) -> [Float] {
        if playerHasAudio { return samples }
        let elapsed = max(0, now.timeIntervalSince(startsAt))
        let already = Int(elapsed * sampleRate)
        guard already < samples.count else { return [] }
        return Array(samples[already...])
    }

    public var milliseconds: Int { Int(Double(samples.count) / sampleRate * 1000) }
}
