import Foundation

/// The VAD's edges, held to the room's own noise floor.
///
/// Silero says "speech" at p ≥ 0.85 and "not" below 0.70, whatever the room
/// is doing — and in the owner's log it said "speech" to a fan, a dish rack,
/// a TV and the canceller's residue, at levels the captured audio later
/// measured as "0.00 of the opening level". It has no idea how loud the room
/// is. This does: it keeps a slow low percentile of the level (the floor),
/// and an onset only counts when the sound clears that floor by a margin.
/// While the VAD insists on speech but the level has sat on the floor for a
/// while, the speech is over whatever the VAD says — which is how steady
/// noise used to hold a turn open with no pause ever reported.
///
/// Deliberately conservative. A voice near the microphone is 15–30 dB over
/// a quiet room; the margin asks for 5. Until the floor has been measured
/// (a couple of seconds after the graph comes up), edges pass through as
/// they always did.
public struct NoiseFloorGate: Sendable {

    public struct Tuning: Equatable, Sendable {
        /// How many level readings the floor is taken over. One per VAD
        /// chunk (256 ms), so 60 is about fifteen seconds.
        public var window = 60
        /// Which low percentile of those readings is the floor. Speech has
        /// gaps, so even a person talking the whole time leaves the floor
        /// on the room rather than on their voice.
        public var percentile = 0.1
        /// Readings needed before the floor is trusted.
        public var minReadings = 8
        /// An onset must peak this far over the floor to count.
        public var onsetMarginDb: Float = 5
        /// While the VAD says speech, a chunk peaking within this of the
        /// floor is the room…
        public var holdMarginDb: Float = 3
        /// …and this many of them in a row (≈ 0.77 s) end the speech.
        public var quietChunksToEnd = 3
        /// A chunk that peaks this far over the recent sound (`riseBed`)
        /// while the speech is already on is a voice *joining* it: `.rose`.
        /// Zero turns rises off. Chosen on the turn bench's dev split
        /// (2026-09-24): 8 / 10 / 12 dB missed 24 / 26 / 29% of real
        /// interruptions (57% with no rises) for 61 / 59 / 57 false stops
        /// (50 with none).
        public var riseMarginDb: Float = 10
        /// The recent sound a rise is measured against: this percentile of
        /// the last `riseBedChunks` chunk peaks (≈ 2 s) that were sound at all.
        public var riseBedChunks = 8
        public var riseBedPercentile = 0.5
        public init() {}
    }

    public enum VadEdge: Equatable, Sendable { case start, end }
    /// `.rose`: the speech was already on, and a louder voice joined it.
    ///
    /// Why it exists (turn bench, 2026-09-24): over a playing reply Silero
    /// calls the canceller's residue of Moe's own voice speech — correctly,
    /// it is speech — and stays "in speech" from the reply's first word to
    /// its last. The only onset is that first one, which the machine judges
    /// and lets go; the person talking over Moe a few seconds later then
    /// makes no edge at all. 258 of the 337 missed interruptions on the
    /// test split were exactly that. A person is well over the echo, so
    /// the level says what the VAD cannot.
    public enum Edge: Equatable, Sendable { case started, ended, rose }

    public var tuning = Tuning()
    private var readings: [Float] = []
    public private(set) var floorDb: Float?
    /// What the VAD itself says.
    public private(set) var vadInSpeech = false
    /// What has been reported onward.
    public private(set) var inSpeech = false
    private var quietRun = 0
    /// Onsets the floor refused since the last reported one — for the log.
    public private(set) var refusedOnsets = 0
    /// The last `riseBedChunks` chunk peaks, whatever the VAD said.
    private var recentPeaks: [Float] = []

    public init() {}

    /// Feed one VAD chunk: its mean level, its loudest 32 ms frame, and the
    /// edge the VAD reported on it, if any. Returns the edge to report.
    public mutating func observe(chunkDb: Float, peakDb: Float, vad edge: VadEdge?) -> Edge? {
        // The room is learned from the room: not while a voice is clear of
        // it, or a long fluent turn drags the floor up towards soft speech
        // and the hold rule starts ending real speech (review L3).
        if !inSpeech { learn(chunkDb) }
        switch edge {
        case .start?:
            vadInSpeech = true
        case .end?:
            vadInSpeech = false
        case nil:
            break
        }
        let bed = riseBed()
        remember(peakDb)
        if inSpeech {
            if !vadInSpeech {
                inSpeech = false
                quietRun = 0
                return .ended
            }
            if let floor = floorDb, peakDb < floor + tuning.holdMarginDb {
                quietRun += 1
                if quietRun >= tuning.quietChunksToEnd {
                    inSpeech = false
                    quietRun = 0
                    return .ended
                }
            } else {
                quietRun = 0
            }
            if tuning.riseMarginDb > 0, let bed, peakDb >= bed + tuning.riseMarginDb {
                return .rose
            }
            return nil
        }
        guard vadInSpeech else { return nil }
        if let floor = floorDb, peakDb < floor + tuning.onsetMarginDb {
            // Speech-shaped, and no louder than the room: not an onset yet.
            // It becomes one the moment it rises clear of the floor.
            if edge == .start { refusedOnsets += 1 }
            return nil
        }
        inSpeech = true
        quietRun = 0
        return .started
    }

    /// Between owners of the microphone: the VAD starts again from quiet.
    /// The floor is the room's and is kept.
    public mutating func resetSpeech() {
        vadInSpeech = false
        inSpeech = false
        quietRun = 0
    }

    /// What a rise is measured against: the recent chunks that were sound
    /// at all — clear of the room, and not digital silence (the gap between
    /// two sentences of a reply can be a chunk of nothing, and would drag
    /// the bed down to it). Nil with fewer than two such chunks.
    func riseBed() -> Float? {
        let quiet = max(-70, (floorDb ?? -100) + tuning.holdMarginDb)
        let heard = recentPeaks.filter { $0 >= quiet }.sorted()
        guard heard.count >= 2 else { return nil }
        let i = min(heard.count - 1, max(0, Int((Double(heard.count - 1) * tuning.riseBedPercentile).rounded())))
        return heard[i]
    }

    private mutating func remember(_ peakDb: Float) {
        guard peakDb.isFinite else { return }
        recentPeaks.append(peakDb)
        if recentPeaks.count > tuning.riseBedChunks {
            recentPeaks.removeFirst(recentPeaks.count - tuning.riseBedChunks)
        }
    }

    private mutating func learn(_ db: Float) {
        guard db.isFinite else { return }
        readings.append(max(-100, min(0, db)))
        if readings.count > tuning.window { readings.removeFirst(readings.count - tuning.window) }
        guard readings.count >= tuning.minReadings else { floorDb = nil; return }
        let sorted = readings.sorted()
        let i = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * tuning.percentile)))
        floorDb = sorted[i]
    }

    /// dBFS of a block, and of its loudest `frame`-sample stretch.
    public static func levels(_ samples: [Float], frame: Int = 512) -> (meanDb: Float, peakDb: Float) {
        guard !samples.isEmpty else { return (-100, -100) }
        func db(_ sum: Float, _ n: Int) -> Float { 10 * log10(max(sum / Float(max(n, 1)), 1e-12)) }
        var total: Float = 0
        var peak: Float = 0
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + frame)
            var sum: Float = 0
            for s in samples[i..<end] { sum += s * s }
            total += sum
            peak = max(peak, sum / Float(end - i))
            i = end
        }
        return (db(total, samples.count), 10 * log10(max(peak, 1e-12)))
    }
}
