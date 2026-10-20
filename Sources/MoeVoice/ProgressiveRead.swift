import Foundation

/// The accurate re-read, started before the turn is decided.
///
/// The VAD reports that the person has stopped 250 ms after they do, and the
/// machine then spends 400 ms of endpointer debounce, or a turn-model call,
/// deciding that the turn is over. Until 2026-09-06 the accurate model was
/// started only *after* that decision, so its whole cost sat between the
/// last word and the brain — on the owner's turns of 2026-09-05/06 (283
/// `turn: re-read` lines): 150 ms p50, 392 ms p90, 985 ms max. Now it starts
/// on the VAD's edge, on what the capture holds at that moment, and when the
/// turn is decided the only question is whether anything was said since.
///
/// **Why this shape, and not a streaming decoder.** FluidAudio 0.15.6 does
/// ship one for this model — `SlidingWindowAsrManager`, carrying a
/// `TdtDecoderState` across windows — but every window it runs, like every
/// other Parakeet call, is zero-padded to the encoder's fixed 15 s input
/// (`AsrManager+Transcription.swift:17`, `padAudioIfNeeded(…, targetLength:
/// ASRConstants.maxModelSamples)`; the chunk path does the same at :96), so a
/// read has a floor of one full encoder pass whatever it contains. Measured
/// on this Mac on 2026-09-06, TDT 0.6B v3, p50 of 12:
///
///     1 s of silence               71 ms      ← the floor
///     1 s of speech                70 ms
///     5 s                         104 ms
///     10 s                        133 ms
///     14 s                        150 ms
///     last 1.5–2 s of a 10 s turn  82–87 ms
///     last 1 s, cut mid-word       75 ms — and it decoded to ""
///     SlidingWindowAsrManager.finish() after 10 s streamed   442 ms
///
/// So a tail read saves ~50 ms of a 130 ms read and can lose the word it
/// cuts through; the streaming manager's `finish()` costs three whole reads.
/// Reading everything early and *skipping* the tail when it is quiet saves
/// the whole read, and decodes the same audio the old path did minus some
/// trailing silence: on 24 LibriSpeech test-clean pairs (~8 s each) the text
/// after 0.25 s of trailing quiet was identical to the text after 0.7 s in
/// 24 of 24, WER 3.24% both ways.
///
/// Nothing here touches a model. This is the arithmetic that decides whether
/// an early read may stand for the turn — pure, so it is testable without one.
public enum ProgressiveRead {

    /// What an early read was run on: enough to prove, later, that the turn
    /// as taken begins with exactly this audio. The buffer itself is not kept
    /// — it is the capture — only its length and its two ends.
    public struct Snapshot: Sendable, Equatable {
        public let count: Int
        let head: [Float]
        let tail: [Float]
        /// 100 ms at 16 kHz, each end.
        static let edge = 1600

        public init(_ samples: [Float]) {
            count = samples.count
            head = Array(samples.prefix(Self.edge))
            tail = Array(samples.suffix(Self.edge))
        }
    }

    public enum Coverage: Sendable, Equatable {
        /// The turn is the snapshot plus nothing but quiet: the early read
        /// stands. `quietSeconds` is how much quiet followed it.
        case stands(quietSeconds: Double)
        /// It is not, and `why` says so for the log.
        case stale(String)
    }

    /// Anything above this fraction of the turn's loudest 10 ms frame, after
    /// the snapshot, is speech the read did not hear. `TurnAudio` trims
    /// trailing silence at 5%; this is stricter on purpose: there a wrong
    /// call hands a model a slightly longer pause, here it drops a word.
    /// The microphone floor in the fixtures is ~0.3% of a spoken peak, so
    /// 2% still clears room tone by a wide margin.
    public static let quietFraction: Float = 0.02

    /// Whether `audio` — the turn as taken — is what `snapshot` read, with
    /// nothing but quiet after it.
    public static func coverage(of snapshot: Snapshot, in audio: [Float],
                                sampleRate: Int = 16_000) -> Coverage {
        guard snapshot.count > 0 else { return .stale("nothing was read") }
        guard snapshot.count <= audio.count else {
            return .stale("the capture is shorter than the read (\(snapshot.count) > \(audio.count) samples)")
        }
        guard Array(audio.prefix(snapshot.head.count)) == snapshot.head,
              Array(audio[(snapshot.count - snapshot.tail.count)..<snapshot.count]) == snapshot.tail
        else { return .stale("the capture changed under the read") }

        let rest = audio.count - snapshot.count
        let quiet = Double(rest) / Double(sampleRate)
        guard rest > 0 else { return .stands(quietSeconds: 0) }

        // 10 ms RMS frames over the whole turn: the peak is the person, and
        // the frames from the boundary on are what has to be quiet. The frame
        // straddling the boundary counts as "after", which is the strict side.
        let frame = sampleRate / 100
        var levels: [Float] = []
        levels.reserveCapacity(audio.count / frame + 1)
        var peak: Float = 0
        var i = 0
        while i + frame <= audio.count {
            var sum: Float = 0
            for s in audio[i..<(i + frame)] { sum += s * s }
            let level = (sum / Float(frame)).squareRoot()
            levels.append(level)
            peak = max(peak, level)
            i += frame
        }
        guard peak > 0 else { return .stands(quietSeconds: quiet) }
        let floor = peak * quietFraction
        let firstAfter = min(levels.count, snapshot.count / frame)
        if let loud = levels[firstAfter...].firstIndex(where: { $0 > floor }) {
            let at = max(0, Double(loud * frame - snapshot.count) / Double(sampleRate))
            return .stale(String(format: "speech %.2f s after the read", at))
        }
        return .stands(quietSeconds: quiet)
    }

    /// Whether an early read should start at all. Off, not ready, not
    /// capturing, or not the local engine — any one of them and nothing
    /// starts, which leaves the turn on exactly the path it took before.
    /// `local` is false for Whisper (too slow to run twice) and must be false
    /// for a cloud recogniser reading the turn live, so two recognisers
    /// never read one turn.
    public static func shouldStart(enabled: Bool, accurateReady: Bool,
                                   capturing: Bool, local: Bool) -> Bool {
        enabled && accurateReady && capturing && local
    }
}

/// Holds the one early read that may stand for the next turn, and the two
/// rules the machine's batches impose on it.
///
/// `.transcribe` and `.capture(false)` arrive in one batch, in that order
/// (`VoiceMachine.handle`: the transition appends `.transcribe`, the derived
/// diff appends `.capture` after it). The turn's read must therefore *claim*
/// the pending read synchronously, before the capture-off that follows
/// discards it — the same trap the cloud path's live turn hit. And a read
/// is a prefix of exactly one capture: capture on (a new owner of the
/// buffer), capture off, or the person speaking again each make it moot.
public struct ProgressiveSlot<Pending: Sendable>: Sendable {
    public private(set) var pending: Pending?
    /// Bumped on every `begin`, so a task finishing late can tell it was
    /// replaced.
    public private(set) var generation = 0

    public init() {}

    /// A new read: replaces whatever was pending.
    @discardableResult
    public mutating func begin(_ p: Pending) -> Int {
        generation &+= 1
        pending = p
        return generation
    }

    /// The turn is being read: hand the pending read over, once.
    public mutating func claim() -> Pending? {
        defer { pending = nil }
        return pending
    }

    /// Capture on or off, or speech resumed: nothing pending is a prefix of
    /// anything any more.
    public mutating func discard() { pending = nil }

    public var isPending: Bool { pending != nil }
}
