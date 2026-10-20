import Foundation

/// The pauses inside one turn that the person talked through — labelled
/// holds, free (research-endpointing.md §6.2). A held-key turn is the best
/// source there is: the key says when they were really done, so every pause
/// before the release is a hold. A hands-free turn gives the pauses the
/// endpoint waited out.
///
/// Kept on the turn's trace as durations (`TurnTrace.holdsMs`, numbers only,
/// always) and in a debug clip's sidecar as spans (`VoiceDebug.Sidecar.holds`,
/// only with `voiceDebugAudio`), so a real training set of the owner's own
/// pauses accumulates on their Mac.
public struct TurnPauses: Equatable, Sendable {
    /// A pause, in seconds from when the capture opened.
    public struct Span: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var duration: Double { end - start }
    }

    /// Shorter than this is a gap between words, not a pause anyone decides on
    /// (eot-bench counts from 0.1 s; Moe's VAD ends a segment only after
    /// 0.25 s of quiet, so every edge it reports is already longer).
    public static let shortest = 0.2

    public private(set) var spans: [Span] = []
    private var endedAt: Double?

    public init() {}

    /// The VAD said the person stopped, `t` seconds into the capture.
    public mutating func ended(at t: Double) { endedAt = t }

    /// …and started again: the time between was a pause they talked through.
    public mutating func started(at t: Double) {
        guard let e = endedAt else { return }
        endedAt = nil
        if t - e >= Self.shortest { spans.append(Span(start: e, end: t)) }
    }

    /// Durations in whole milliseconds, for the trace; nil when there were none.
    public var durationsMs: [Int]? {
        spans.isEmpty ? nil : spans.map { Int(($0.duration * 1000).rounded()) }
    }
}

/// The owner's own pause habit, learnt from their logged turns: how long
/// they go quiet mid-turn and then carry on (research-endpointing.md §4.5).
///
/// From the holds on their turn traces (`TurnTrace.holdsMs`) and the
/// continuations ("the pause was a breath", `TurnTrace.continuedAfterMs`) it
/// takes a high quantile — the quiet that `quantile` of their holds fit
/// inside — and offers it as a floor under the reply's hold
/// (`EndpointPolicy.ownerQuietFloor`), clamped so no habit makes Moe either
/// jumpy or deaf. **Off by default** (`Config.turnOwnerPauses`), and with it
/// on, nothing happens until `minHolds` pauses have been seen: an estimate
/// from a handful of pauses is a guess, and a guess here is felt on every turn.
public struct OwnerPauses: Equatable, Sendable {
    public var quantile: Double
    public var minHolds: Int
    public var lowest: Double
    public var highest: Double
    /// Only the most recent pauses count: habits (and microphones) change.
    public var window: Int

    public init(quantile: Double = 0.9, minHolds: Int = 50, lowest: Double = 0.8,
                highest: Double = 2.5, window: Int = 500) {
        self.quantile = quantile; self.minHolds = minHolds
        self.lowest = lowest; self.highest = highest; self.window = window
    }

    /// Pauses that were holds, in seconds, from turn-trace JSON lines (oldest
    /// first). Pauses over `highest`×2 are left out: a person stopping for
    /// five seconds mid-turn is thinking, not breathing, and the mid-clause
    /// ceiling is what covers that.
    public func holds(fromTraceLines lines: [String]) -> [Double] {
        var out: [Double] = []
        let dec = JSONDecoder()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let row = try? dec.decode(Row.self, from: data) else { continue }
            for ms in row.holdsMs ?? [] { out.append(Double(ms) / 1000) }
            if let ms = row.continuedAfterMs { out.append(Double(ms) / 1000) }
        }
        return Array(out.filter { $0 >= TurnPauses.shortest && $0 <= highest * 2 }.suffix(window))
    }

    private struct Row: Decodable { let holdsMs: [Int]?; let continuedAfterMs: Int? }

    /// The floor under the reply's hold, or nil — not enough pauses yet.
    public func floor(_ holds: [Double]) -> Double? {
        guard holds.count >= minHolds else { return nil }
        let sorted = holds.sorted()
        let i = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * quantile).rounded())))
        return min(highest, max(lowest, sorted[i]))
    }
}
